package core

import (
	"bufio"
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeQMP accepts one client, greets it, answers commands and emits SHUTDOWN after quit.
func fakeQMP(t *testing.T) string {
	path := filepath.Join(t.TempDir(), "qmp.sock")
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		conn, err := l.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.Write([]byte(`{"QMP": {"version": {"qemu": {"major": 11}}, "capabilities": []}}` + "\r\n"))
		sc := bufio.NewScanner(conn)
		for sc.Scan() {
			var m struct {
				Execute string `json:"execute"`
				ID      int    `json:"id"`
			}
			json.Unmarshal(sc.Bytes(), &m)
			switch m.Execute {
			case "qmp_capabilities", "system_powerdown":
				conn.Write([]byte(sprintf(`{"return": {}, "id": %d}`+"\r\n", m.ID)))
			case "quit":
				conn.Write([]byte(sprintf(`{"return": {}, "id": %d}`+"\r\n", m.ID)))
				conn.Write([]byte(`{"timestamp": {"seconds": 1, "microseconds": 2}, "event": "SHUTDOWN", "data": {"guest": false, "reason": "host-qmp-quit"}}` + "\r\n"))
				return
			default:
				conn.Write([]byte(sprintf(`{"error": {"class": "CommandNotFound", "desc": "The command %s has not been found"}, "id": %d}`+"\r\n", m.Execute, m.ID)))
			}
		}
	}()
	return path
}

func TestQMPClient(t *testing.T) {
	c, err := DialQMP(fakeQMP(t), 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, err := c.Execute("system_powerdown", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Execute("nope", nil); err == nil || !strings.Contains(err.Error(), "CommandNotFound") {
		t.Fatalf("error reply: %v", err)
	}
	if _, err := c.Execute("x-debug", nil); err == nil {
		t.Fatal("x- command allowed")
	}
	if _, err := c.Execute("quit", nil); err != nil {
		t.Fatal(err)
	}
	ev, ok := <-c.Events
	if !ok || ev.Name != "SHUTDOWN" || ev.Data["reason"] != "host-qmp-quit" {
		t.Fatalf("event %+v %v", ev, ok)
	}
	select {
	case <-c.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("connection end not noticed")
	}
	if _, err := c.Execute("system_powerdown", nil); err == nil {
		t.Fatal("execute after close succeeded")
	}
}

func TestQMPGreetingTimeout(t *testing.T) {
	path := filepath.Join(t.TempDir(), "qmp.sock")
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go func() {
		conn, _ := l.Accept()
		if conn != nil {
			time.Sleep(time.Second)
			conn.Close()
		}
	}()
	if _, err := DialQMP(path, 200*time.Millisecond); err == nil {
		t.Fatal("dial without greeting succeeded")
	}
}
