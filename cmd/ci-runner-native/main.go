// ci-runner-native is the native U8 service owner for the existing Farm engine.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/unraid/ci-runner-farm/internal/capacitycmd"
	"github.com/unraid/ci-runner-farm/internal/localchecks"
	"github.com/unraid/ci-runner-farm/internal/nativebackend"
	"github.com/unraid/ci-runner-farm/pkg/farmcapacity"
	"github.com/unraid/ci-runner-farm/pkg/hostcapacity"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--local-checks-probe" {
		if err := localchecks.WriteKernelProbe(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "local_checks_kernel_probe_failed")
			os.Exit(1)
		}
		return
	}

	if len(os.Args) == 3 && os.Args[1] == "--local-checks" {
		ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
		defer cancel()
		if err := localchecks.RunProtected(ctx, os.Args[2], os.Stdin, os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "local_checks_native_operation_failed")
			os.Exit(1)
		}
		return
	}

	if len(os.Args) == 2 && os.Args[1] == "--migration-inspect" {
		if os.Geteuid() != 0 {
			fmt.Fprintln(os.Stderr, "root required")
			os.Exit(2)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		status, err := nativebackend.InspectClassicMigration(ctx)
		if err != nil {
			fmt.Fprintln(os.Stderr, "migration_inventory_unavailable")
			os.Exit(1)
		}
		if json.NewEncoder(os.Stdout).Encode(status) != nil {
			os.Exit(1)
		}
		return
	}
	// The embedded engine's capacity symlink runs the unchanged allocator command,
	// including its root/same-file inherited FD8 and durable ownership checks.
	if filepath.Base(os.Args[0]) == "ci-runner-capacity" {
		if err := capacitycmd.Run(os.Args[1:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "capacity operation failed")
			if errors.Is(err, farmcapacity.ErrQueued) {
				os.Exit(75)
			}
			if errors.Is(err, farmcapacity.ErrCredentialsExpired) {
				os.Exit(76)
			}
			os.Exit(1)
		}
		return
	}
	config := flag.String("config-dir", "", "Core HostStorage settings directory")
	runtime := flag.String("runtime-dir", "", "Core NativeService runtime directory")
	cache := flag.String("cache-root", "", "Core-owned persistent runner-cache binding")
	flag.Parse()
	if os.Geteuid() != 0 || *config == "" || *runtime == "" || *cache == "" || flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "native_backend_requires_root_and_managed_paths")
		os.Exit(2)
	}
	if err := run(*config, *runtime, *cache); err != nil {
		fmt.Fprintln(os.Stderr, "native_backend_failed:", err)
		os.Exit(1)
	}
}
func run(config, runtime, cache string) error {
	resolved, err := filepath.EvalSymlinks(cache)
	if err != nil || !filepath.IsAbs(cache) || filepath.Clean(cache) != cache || resolved != cache {
		return errors.New("canonical_bound_cache_required")
	}
	if err := nativebackend.CheckDirectory(config, 0); err != nil {
		return err
	}
	if err := os.MkdirAll(runtime, 0700); err != nil {
		return err
	}
	if err := nativebackend.CheckDirectory(runtime, 0); err != nil {
		return err
	}
	checkctx, cancelCheck := context.WithTimeout(context.Background(), 3*time.Second)
	status, checkErr := nativebackend.InspectClassicMigration(checkctx)
	cancelCheck()
	if checkErr != nil {
		return checkErr
	}
	if !status.Ready {
		return errors.New("classic_owner_requires_supported_retirement")
	}
	engineRuntime := "/var/local/emhttp/ci-runner-farm"
	if err := os.MkdirAll(engineRuntime, 0700); err != nil {
		return err
	}
	if err := nativebackend.CheckDirectory(engineRuntime, 0); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(engineRuntime, "native-owner.lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("native_owner_already_active")
	}
	socket := filepath.Join(runtime, "backend.sock")
	// Holding the exclusive owner lock proves any socket at our fixed managed
	// location belongs to a previous dead generation. Never unlink other types.
	if info, err := os.Lstat(socket); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return errors.New("unexpected_socket_path_type")
		}
		if err = os.Remove(socket); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	root, err := os.MkdirTemp(runtime, "engine-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	engine := &nativebackend.Engine{Root: root, Config: config, Runtime: engineRuntime, CapacityRoot: filepath.Dir(hostcapacity.ConfigPath), Executable: executable, BoundCache: cache}
	if err = engine.Extract(); err != nil {
		return err
	}
	service := nativebackend.New(engine, config, engineRuntime)
	defer service.Shutdown()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()
	schedulerDone := make(chan struct{})
	go func() { defer close(schedulerDone); service.RunScheduler(ctx) }()
	err = service.Serve(ctx, socket)
	cancel()
	<-schedulerDone
	return err
}
