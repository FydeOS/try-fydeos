package core

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

const jobHelperEnv = "TRYFYDEOS_JOB_HELPER"

// The helper modes run before TestMain: "parent" joins the job and starts a
// "child" that would sleep forever, then prints the child's pid and waits.
func init() {
	switch os.Getenv(jobHelperEnv) {
	case "parent":
		if err := joinKillOnCloseJob(); err != nil {
			fmt.Println("error", err)
			os.Exit(1)
		}
		child := exec.Command(os.Args[0])
		child.Env = append(os.Environ(), jobHelperEnv+"=child")
		if err := child.Start(); err != nil {
			fmt.Println("error", err)
			os.Exit(1)
		}
		fmt.Println(child.Process.Pid)
		time.Sleep(time.Hour)
	case "child":
		time.Sleep(time.Hour)
	}
}

func TestChildDiesWithKilledLauncher(t *testing.T) {
	parent := exec.Command(os.Args[0])
	parent.Env = append(os.Environ(), jobHelperEnv+"=parent")
	out, _ := parent.StdoutPipe()
	if err := parent.Start(); err != nil {
		t.Fatal(err)
	}
	line, _ := bufio.NewReader(out).ReadString('\n')
	pid, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil {
		parent.Process.Kill()
		t.Fatalf("helper said %q", line)
	}
	h, err := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(h)
	if ev, _ := windows.WaitForSingleObject(h, 200); ev != uint32(windows.WAIT_TIMEOUT) {
		t.Fatal("child exited before the parent was killed")
	}
	parent.Process.Kill()
	parent.Wait()
	if ev, _ := windows.WaitForSingleObject(h, uint32((5 * time.Second).Milliseconds())); ev != windows.WAIT_OBJECT_0 {
		windows.TerminateProcess(h, 1)
		t.Fatal("child survived the killed parent")
	}
}
