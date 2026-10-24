package nativebackend

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"
)

// RunScheduler owns foreground engine ticks. Busy operators win; no queued tick
// survives to execute using an expired observation. All configured cadences use
// existing engine settings rather than adding another demand planner.
func (s *Service) RunScheduler(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	s.runScheduler(ctx, ticker.C)
}

func (s *Service) runScheduler(ctx context.Context, ticks <-chan time.Time) {
	_, initialErr := os.Stat(filepath.Join(s.config, "native-fleet.enabled"))
	restorePending := initialErr == nil
	next := map[string]time.Time{}
	var config map[string]any
	nextConfig := time.Time{}
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticks:
			if _, err := os.Stat(filepath.Join(s.config, "ci-runner-farm.cfg")); err != nil {
				continue
			}
			if _, err := os.Stat(filepath.Join(s.config, "native-fleet.enabled")); err != nil {
				restorePending = false
				continue
			}
			s.mu.Lock()
			ready := s.accepting && s.active == nil
			s.mu.Unlock()
			if !ready {
				continue
			}
			if restorePending {
				// Reuse the original bounded boot/Docker readiness workflow once
				// per backend activation. Recurring full starts would undo an
				// operator's Scale0 and re-run explicit-start side effects.
				result := s.launch(Request{Action: "scheduled-boot-autostart"}, func(jobctx context.Context) (string, error) {
					return s.engine.Run(jobctx, "boot-autostart", nil, "")
				})
				if result.OK {
					restorePending = false
				}
				continue
			}
			if now.After(nextConfig) {
				response := s.query(Request{Action: "settings"})
				if !response.OK {
					continue
				}
				var ok bool
				config, ok = response.Data.(map[string]any)
				if !ok {
					continue
				}
				nextConfig = now.Add(15 * time.Second)
			}
			intervals := map[string]time.Duration{"usage-refresh": 30 * time.Second, "lifecycle-tick": 30 * time.Second, "queued-refresh": 60 * time.Second, "stats-refresh": 5 * time.Minute, "cache-usage-refresh": 5 * time.Minute}
			if config["AUTOSCALE"] == "true" {
				intervals["autoscale-tick"] = seconds(config["AUTOSCALE_INTERVAL"], 30)
			}
			if config["IMAGE_AUTOUPDATE"] == "true" {
				intervals["imageupdate-tick"] = seconds(config["IMAGE_AUTOUPDATE_INTERVAL"], 1800)
			}
			actions := []string{"autoscale-tick", "lifecycle-tick", "usage-refresh", "queued-refresh", "stats-refresh", "cache-usage-refresh", "imageupdate-tick"}
			if _, err := os.Stat(filepath.Join(s.runtime, "native-reconcile.pending")); err == nil {
				actions = append([]string{"reconcile-drain"}, actions...)
				intervals["reconcile-drain"] = 15 * time.Second
			}
			if _, err := os.Stat(filepath.Join(s.runtime, "imageupdate.pending")); err == nil && config["IMAGE_AUTOUPDATE"] == "true" {
				actions = append([]string{"native-image-drain-tick"}, actions...)
				intervals["native-image-drain-tick"] = 15 * time.Second
			}
			for _, action := range actions {
				interval, enabled := intervals[action]
				if !enabled || now.Before(next[action]) {
					continue
				}
				selected := action
				result := s.launch(Request{Action: "scheduled-" + selected}, func(jobctx context.Context) (string, error) {
					out, err := s.engine.Run(jobctx, selected, nil, "")
					if selected == "reconcile-drain" && err == nil {
						_ = os.Remove(filepath.Join(s.runtime, "native-reconcile.pending"))
					}
					var exited *exec.ExitError
					if selected == "reconcile-drain" && errors.As(err, &exited) && exited.ExitCode() == 75 {
						return out, nil
					}
					return out, err
				})
				if result.OK {
					next[action] = now.Add(interval)
				}
				break
			}
		}
	}
}
func seconds(value any, fallback int) time.Duration {
	v, ok := value.(string)
	if !ok {
		return time.Duration(fallback) * time.Second
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > 86400 {
		n = fallback
	}
	return time.Duration(n) * time.Second
}
