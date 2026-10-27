// Package payloadtest builds a minimal PE image for tests.
package payloadtest

import (
	"bytes"
	"debug/pe"
	"encoding/binary"
)

const (
	peOffset = 0x40
	// OptionalHeaderOffset is where the PE32+ optional header starts.
	OptionalHeaderOffset = peOffset + 4 + 20
	// ImageEnd is where the one section's raw data ends: the overlay start.
	ImageEnd    = sectionData + 0x200
	sectionData = 0x400
)

// FakePE is a PE32+ image with one 0x200-byte section at 0x400.
func FakePE() []byte {
	var b bytes.Buffer
	dos := make([]byte, peOffset)
	copy(dos, "MZ")
	binary.LittleEndian.PutUint32(dos[0x3c:], peOffset)
	b.Write(dos)
	b.WriteString("PE\x00\x00")
	oh := pe.OptionalHeader64{Magic: 0x20b, FileAlignment: 0x200, SectionAlignment: 0x1000,
		SizeOfHeaders: sectionData, SizeOfImage: 0x2000, NumberOfRvaAndSizes: 16, Subsystem: 3}
	binary.Write(&b, binary.LittleEndian, pe.FileHeader{Machine: pe.IMAGE_FILE_MACHINE_AMD64, NumberOfSections: 1,
		SizeOfOptionalHeader: uint16(binary.Size(oh)), Characteristics: 0x22})
	binary.Write(&b, binary.LittleEndian, oh)
	sh := pe.SectionHeader32{VirtualSize: 0x100, VirtualAddress: 0x1000, SizeOfRawData: 0x200,
		PointerToRawData: sectionData, Characteristics: 0x60000020}
	copy(sh.Name[:], ".text")
	binary.Write(&b, binary.LittleEndian, sh)
	b.Write(make([]byte, sectionData-b.Len()))
	b.Write(bytes.Repeat([]byte{0xc3}, 0x200))
	return b.Bytes()
}
