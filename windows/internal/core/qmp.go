package core

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

type QMPEvent struct {
	Name string         `json:"event"`
	Data map[string]any `json:"data"`
}

type qmpMessage struct {
	QMP    json.RawMessage `json:"QMP"`
	Event  string          `json:"event"`
	Data   map[string]any  `json:"data"`
	ID     *int            `json:"id"`
	Return json.RawMessage `json:"return"`
	Error  *struct {
		Class string `json:"class"`
		Desc  string `json:"desc"`
	} `json:"error"`
}

var ErrQMPClosed = errors.New("QMP connection closed")

// QMPClient is one QMP connection: a reader goroutine matches replies to
// requests by id and delivers events on Events, which is closed when the
// connection ends. QEMU serves one QMP client at a time.
type QMPClient struct {
	conn    net.Conn
	Timeout time.Duration
	Events  chan QMPEvent

	mu       sync.Mutex
	nextID   int
	pending  map[int]chan qmpMessage
	greeting chan struct{}
	done     chan struct{}
}

func DialQMP(path string, timeout time.Duration) (*QMPClient, error) {
	conn, err := net.DialTimeout("unix", path, timeout)
	if err != nil {
		return nil, err
	}
	c := &QMPClient{
		conn: conn, Timeout: timeout, Events: make(chan QMPEvent, 64),
		nextID: 1, pending: map[int]chan qmpMessage{}, greeting: make(chan struct{}), done: make(chan struct{}),
	}
	go c.readLoop()
	select {
	case <-c.greeting:
	case <-c.done:
		return nil, ErrQMPClosed
	case <-time.After(timeout):
		c.Close()
		return nil, errors.New("QMP timeout waiting for greeting (another client may hold the QMP socket)")
	}
	if _, err := c.Execute("qmp_capabilities", nil); err != nil {
		c.Close()
		return nil, err
	}
	return c, nil
}

func (c *QMPClient) readLoop() {
	defer func() {
		c.mu.Lock()
		for id, ch := range c.pending {
			close(ch)
			delete(c.pending, id)
		}
		c.mu.Unlock()
		close(c.Events)
		close(c.done)
	}()
	sc := bufio.NewScanner(c.conn)
	sc.Buffer(make([]byte, 64<<10), 16<<20)
	greeted := false
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var m qmpMessage
		if json.Unmarshal([]byte(line), &m) != nil {
			continue
		}
		switch {
		case m.Event != "":
			select {
			case c.Events <- QMPEvent{Name: m.Event, Data: m.Data}:
			default:
			}
		case m.QMP != nil && !greeted:
			greeted = true
			close(c.greeting)
		case m.ID != nil:
			c.mu.Lock()
			ch := c.pending[*m.ID]
			delete(c.pending, *m.ID)
			c.mu.Unlock()
			if ch != nil {
				ch <- m
			}
		}
	}
}

// Done is closed once the connection has ended and every event was delivered.
func (c *QMPClient) Done() <-chan struct{} { return c.done }

func (c *QMPClient) Execute(command string, arguments map[string]any) (json.RawMessage, error) {
	if strings.HasPrefix(command, "x-") {
		return nil, fmt.Errorf("QMP command %s refused: x- commands are unstable and can abort QEMU", command)
	}
	ch := make(chan qmpMessage, 1)
	c.mu.Lock()
	id := c.nextID
	c.nextID++
	c.pending[id] = ch
	c.mu.Unlock()
	msg := map[string]any{"execute": command, "id": id}
	if arguments != nil {
		msg["arguments"] = arguments
	}
	data, _ := json.Marshal(msg)
	c.conn.SetWriteDeadline(time.Now().Add(c.Timeout))
	if _, err := c.conn.Write(append(data, '\r', '\n')); err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, ErrQMPClosed
	}
	var m qmpMessage
	var ok bool
	select {
	case m, ok = <-ch:
	case <-c.done:
		// The reply may have arrived just before the connection ended.
		select {
		case m, ok = <-ch:
		default:
		}
	case <-time.After(c.Timeout):
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, fmt.Errorf("QMP timeout waiting for %s", command)
	}
	if !ok {
		return nil, ErrQMPClosed
	}
	if m.Error != nil {
		return nil, fmt.Errorf("QMP %s failed: %s: %s", command, m.Error.Class, m.Error.Desc)
	}
	return m.Return, nil
}

func (c *QMPClient) Close() { c.conn.Close() }
