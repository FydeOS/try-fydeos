// Package vmdk converts the VMDK extents FydeOS publishes for VMware
// (monolithicSparse and streamOptimized) into raw disk data, reading the
// extent strictly forward so it can come straight out of an .ova or .zip.
package vmdk

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sort"
)

const (
	sector         = 512
	magic          = 0x564d444b
	flagCompressed = 1 << 16
	flagMarkers    = 1 << 17

	maxGrainSectors = 1 << 20
	maxDescSectors  = 1 << 11
	maxOverhead     = 1 << 19

	markerEOS = 0
)

// Info describes a parsed extent header.
type Info struct {
	Capacity   int64
	GrainBytes int64
	CreateType string
	Compressed bool
}

type header struct {
	flags        uint32
	capacity     uint64
	grainSize    uint64
	descOffset   uint64
	descSize     uint64
	numGTEsPerGT uint32
	gdOffset     uint64
	overhead     uint64
}

type input struct {
	r   io.Reader
	pos int64
}

func (in *input) read(p []byte) error {
	n, err := io.ReadFull(in.r, p)
	in.pos += int64(n)
	if err == io.EOF || err == io.ErrUnexpectedEOF {
		return fmt.Errorf("truncated at byte %d", in.pos)
	}
	return err
}

func (in *input) skipTo(off int64) error {
	if off < in.pos {
		return fmt.Errorf("data at byte %d overlaps byte %d already read", off, in.pos)
	}
	n, err := io.CopyN(io.Discard, in.r, off-in.pos)
	in.pos += n
	if err == io.EOF {
		return fmt.Errorf("truncated at byte %d", in.pos)
	}
	return err
}

var createTypeRe = regexp.MustCompile(`(?m)^\s*createType\s*=\s*"([^"]*)"`)

func createType(desc []byte) string {
	if m := createTypeRe.FindSubmatch(desc); m != nil {
		return string(m[1])
	}
	return ""
}

func parseHeader(b []byte) (header, error) {
	le := binary.LittleEndian
	if le.Uint32(b[0:]) != magic {
		return header{}, errors.New("not a VMDK sparse extent (bad magic)")
	}
	h := header{
		flags:        le.Uint32(b[8:]),
		capacity:     le.Uint64(b[12:]),
		grainSize:    le.Uint64(b[20:]),
		descOffset:   le.Uint64(b[28:]),
		descSize:     le.Uint64(b[36:]),
		numGTEsPerGT: le.Uint32(b[44:]),
		gdOffset:     le.Uint64(b[56:]),
		overhead:     le.Uint64(b[64:]),
	}
	switch {
	case h.grainSize == 0 || h.grainSize&(h.grainSize-1) != 0 || h.grainSize > maxGrainSectors:
		return h, fmt.Errorf("grain size %d sectors is invalid", h.grainSize)
	case h.capacity == 0 || h.capacity > (1<<63-1)/sector:
		return h, fmt.Errorf("capacity %d sectors is invalid", h.capacity)
	case h.numGTEsPerGT == 0 || h.grainSize*uint64(h.numGTEsPerGT)/uint64(h.numGTEsPerGT) != h.grainSize:
		return h, fmt.Errorf("%d grain table entries per table is invalid", h.numGTEsPerGT)
	case h.descSize > maxDescSectors:
		return h, fmt.Errorf("descriptor size %d sectors is invalid", h.descSize)
	}
	return h, nil
}

// Decode reads one VMDK extent from r and calls write for every allocated grain,
// in file order, with its byte offset in the virtual disk. Zero-filled grains are
// skipped only if the caller does so; Decode delivers what the file stores.
// data is only valid until write returns.
func Decode(r io.Reader, write func(offset int64, data []byte) error) (Info, error) {
	in := &input{r: r}
	head := make([]byte, sector)
	if err := in.read(head); err != nil {
		return Info{}, fmt.Errorf("reading VMDK header: %w", err)
	}
	h, err := parseHeader(head)
	if err != nil {
		return Info{}, err
	}
	info := Info{Capacity: int64(h.capacity) * sector, GrainBytes: int64(h.grainSize) * sector}
	switch h.flags & (flagCompressed | flagMarkers) {
	case flagCompressed | flagMarkers:
		info.Compressed = true
		return info, decodeStream(in, h, &info, write)
	case 0:
		return info, decodeSparse(in, head, h, &info, write)
	}
	return info, fmt.Errorf("unsupported VMDK flags %#x (need both or neither of compressed grains and markers)", h.flags)
}

func decodeSparse(in *input, head []byte, h header, info *Info, write func(int64, []byte) error) error {
	if h.overhead == 0 || h.overhead > maxOverhead {
		return fmt.Errorf("overhead %d sectors is invalid", h.overhead)
	}
	meta := make([]byte, h.overhead*sector)
	copy(meta, head)
	if err := in.read(meta[sector:]); err != nil {
		return fmt.Errorf("reading VMDK metadata: %w", err)
	}
	if h.descOffset != 0 && h.descOffset+h.descSize <= h.overhead {
		info.CreateType = createType(meta[h.descOffset*sector : (h.descOffset+h.descSize)*sector])
	}

	le := binary.LittleEndian
	gtCover := h.grainSize * uint64(h.numGTEsPerGT)
	gdEntries := (h.capacity + gtCover - 1) / gtCover
	gtBytes := uint64(h.numGTEsPerGT) * 4
	if h.gdOffset == 0 || h.gdOffset >= h.overhead || h.gdOffset*sector+gdEntries*4 > h.overhead*sector {
		return fmt.Errorf("grain directory at sector %d lies outside the %d-sector overhead", h.gdOffset, h.overhead)
	}
	type grain struct{ file, lba uint64 }
	var grains []grain
	for i := range gdEntries {
		gt := uint64(le.Uint32(meta[h.gdOffset*sector+i*4:]))
		if gt == 0 {
			continue
		}
		if gt >= h.overhead || gt*sector+gtBytes > h.overhead*sector {
			return fmt.Errorf("grain table %d at sector %d lies outside the %d-sector overhead", i, gt, h.overhead)
		}
		for j := range uint64(h.numGTEsPerGT) {
			g := uint64(le.Uint32(meta[gt*sector+j*4:]))
			if g == 0 {
				continue
			}
			lba := (i*uint64(h.numGTEsPerGT) + j) * h.grainSize
			if lba >= h.capacity {
				return fmt.Errorf("grain at sector %d maps beyond capacity (LBA %d)", g, lba)
			}
			grains = append(grains, grain{g, lba})
		}
	}
	sort.Slice(grains, func(a, b int) bool { return grains[a].file < grains[b].file })

	buf := make([]byte, info.GrainBytes)
	for _, g := range grains {
		if g.file < h.overhead {
			return fmt.Errorf("grain at sector %d lies inside the %d-sector overhead", g.file, h.overhead)
		}
		if err := in.skipTo(int64(g.file) * sector); err != nil {
			return fmt.Errorf("grain at sector %d: %w", g.file, err)
		}
		off := int64(g.lba) * sector
		data := buf[:min(info.GrainBytes, info.Capacity-off)]
		if err := in.read(data); err != nil {
			return fmt.Errorf("grain at sector %d: %w", g.file, err)
		}
		if err := write(off, data); err != nil {
			return err
		}
	}
	return nil
}

func decodeStream(in *input, h header, info *Info, write func(int64, []byte) error) error {
	if h.descOffset != 0 && h.descSize != 0 {
		desc := make([]byte, h.descSize*sector)
		if err := in.skipTo(int64(h.descOffset) * sector); err != nil {
			return fmt.Errorf("reading VMDK descriptor: %w", err)
		}
		if err := in.read(desc); err != nil {
			return fmt.Errorf("reading VMDK descriptor: %w", err)
		}
		info.CreateType = createType(desc)
	}
	if h.overhead <= maxOverhead && int64(h.overhead)*sector > in.pos {
		if err := in.skipTo(int64(h.overhead) * sector); err != nil {
			return fmt.Errorf("reading VMDK overhead: %w", err)
		}
	}

	le := binary.LittleEndian
	maxCompressed := uint64(info.GrainBytes) + uint64(info.GrainBytes)/2 + 2*sector
	buf := make([]byte, (12+maxCompressed+sector-1)/sector*sector)
	grain := make([]byte, info.GrainBytes)
	var probe [1]byte
	var zr io.ReadCloser
	for {
		at := in.pos
		if err := in.read(buf[:sector]); err != nil {
			return fmt.Errorf("reading marker: %w (missing end-of-stream marker)", err)
		}
		val := le.Uint64(buf[0:])
		size := uint64(le.Uint32(buf[8:]))
		if size == 0 {
			typ := le.Uint32(buf[12:])
			if typ == markerEOS {
				return nil
			}
			if val > uint64(h.capacity) {
				return fmt.Errorf("metadata marker type %d at byte %d claims %d sectors", typ, at, val)
			}
			if err := in.skipTo(in.pos + int64(val)*sector); err != nil {
				return fmt.Errorf("metadata marker type %d at byte %d: %w", typ, at, err)
			}
			continue
		}
		if size > maxCompressed {
			return fmt.Errorf("grain at byte %d claims %d compressed bytes", at, size)
		}
		if val >= h.capacity {
			return fmt.Errorf("grain at byte %d maps beyond capacity (LBA %d)", at, val)
		}
		total := (12 + size + sector - 1) / sector * sector
		if err := in.read(buf[sector:total]); err != nil {
			return fmt.Errorf("grain at byte %d: %w", at, err)
		}
		src := bytes.NewReader(buf[12 : 12+size])
		var err error
		if zr == nil {
			zr, err = zlib.NewReader(src)
		} else {
			err = zr.(zlib.Resetter).Reset(src, nil)
		}
		if err != nil {
			return fmt.Errorf("grain at byte %d: %w", at, err)
		}
		off := int64(val) * sector
		n, err := io.ReadFull(zr, grain)
		switch {
		case err == io.ErrUnexpectedEOF && off+int64(n) == info.Capacity:
		case err == io.EOF || err == io.ErrUnexpectedEOF:
			return fmt.Errorf("grain at byte %d inflates to %d bytes, want %d", at, n, len(grain))
		case err != nil:
			return fmt.Errorf("grain at byte %d: %w", at, err)
		default:
			if m, err := zr.Read(probe[:]); m != 0 || err != io.EOF {
				if err != nil && err != io.EOF {
					return fmt.Errorf("grain at byte %d: %w", at, err)
				}
				return fmt.Errorf("grain at byte %d inflates beyond %d bytes", at, len(grain))
			}
		}
		if off+int64(n) > info.Capacity {
			return fmt.Errorf("grain at byte %d ends beyond capacity (LBA %d)", at, val)
		}
		if err := write(off, grain[:n]); err != nil {
			return err
		}
	}
}
