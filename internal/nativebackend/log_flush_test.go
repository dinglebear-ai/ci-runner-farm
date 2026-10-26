package nativebackend

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestEngineLogFlushCoalescesChunksAndCommitsFinalTail(t *testing.T) {
	now := time.Unix(100, 0)
	writes := 0
	var last []byte
	out := &tailBuffer{limit: 512 << 10, logPath: "operation", buildLogPath: "build", now: func() time.Time { return now }, persist: func(_ string, data []byte) error { writes++; last = append([]byte(nil), data...); return nil }}
	for range 100 {
		_, _ = out.Write(bytes.Repeat([]byte("x"), 8192))
	}
	if writes > 2 {
		t.Fatalf("per-chunk persistence: %d", writes)
	}
	if err := out.Flush(); err != nil {
		t.Fatal(err)
	}
	if writes != 4 || !bytes.Equal(last, bytes.Repeat([]byte("x"), 512<<10)) {
		t.Fatal("final tail not committed", writes, len(last))
	}
	now = now.Add(time.Second)
	_, _ = out.Write([]byte("final"))
	if writes != 6 || !bytes.HasSuffix(last, []byte("final")) {
		t.Fatal("progress flush missing", writes)
	}
}

func TestEngineFinalLogIncludesUnflushedTailAfterFailureOrCancellation(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		name := "failed"
		suffix := "exit 7"
		if cancelled {
			name = "cancelled"
			suffix = "sleep 5"
		}
		t.Run(name, func(t *testing.T) {
			e := &Engine{Root: t.TempDir(), Config: t.TempDir(), Runtime: t.TempDir(), CapacityRoot: t.TempDir()}
			if err := os.MkdirAll(filepath.Join(e.Root, "include"), 0700); err != nil {
				t.Fatal(err)
			}
			script := "printf first; sleep 0.01; printf final; " + suffix + "\n"
			if err := os.WriteFile(filepath.Join(e.Root, "include", "runner-farm.sh"), []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			ctx := context.Background()
			if cancelled {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, 200*time.Millisecond)
				defer cancel()
			}
			out, err := e.Run(ctx, "build-image", nil, "")
			if err == nil || out != "firstfinal" {
				t.Fatal(out, err)
			}
			for _, name := range []string{"native-operation.log", "native-build.log"} {
				got, err := os.ReadFile(filepath.Join(e.Runtime, name))
				if err != nil || string(got) != out {
					t.Fatal(name, string(got), err)
				}
			}
		})
	}
}
