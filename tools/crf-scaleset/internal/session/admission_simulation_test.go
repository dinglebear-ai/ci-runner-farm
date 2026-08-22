package session

import (
	"slices"
	"sort"
	"testing"
	"time"

	crfgithub "github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset/internal/github"
)

type simulatedJob struct {
	id       int64
	arrival  time.Duration
	duration time.Duration
	quick    bool
	job      crfgithub.AvailableJob
}

type simulatedRunning struct {
	index  int
	finish time.Duration
}

type simulationMetrics struct {
	quickWaits []time.Duration
	longWaits  []time.Duration
	makespan   time.Duration
}

func simulationJob(base time.Time, id int64, arrival, duration time.Duration, quick bool) simulatedJob {
	name := "rust-build"
	if quick {
		name = "unit"
	}
	return simulatedJob{
		id: id, arrival: arrival, duration: duration, quick: quick,
		job: testJob(id, "dinglebear-ai/soma", "workflow@refs/heads/main", name, base.Add(arrival)),
	}
}

func simulationRuntimeHints(jobs []simulatedJob) map[runtimeDigest]runtimeEstimate {
	runtimes := map[runtimeDigest]runtimeEstimate{}
	for _, job := range jobs {
		runtimes[runtimeKey("build", job.job.Metadata)] = runtimeEstimate{duration: job.duration, samples: 100}
	}
	return runtimes
}

func removeSimulatedQueueIDs(queue []int, jobs []simulatedJob, ids []int64) []int {
	if len(ids) == 0 {
		return queue
	}
	selected := make(map[int64]bool, len(ids))
	for _, id := range ids {
		selected[id] = true
	}
	return slices.DeleteFunc(queue, func(index int) bool { return selected[jobs[index].id] })
}

func percentileDuration(values []time.Duration, percentile int) time.Duration {
	if len(values) == 0 {
		return 0
	}
	ordered := slices.Clone(values)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i] < ordered[j] })
	rank := (percentile*len(ordered) + 99) / 100
	if rank < 1 {
		rank = 1
	}
	if rank > len(ordered) {
		rank = len(ordered)
	}
	return ordered[rank-1]
}

func simulateAdmissionWorkload(t *testing.T, capacity int, jobs []simulatedJob, adaptive bool) simulationMetrics {
	t.Helper()
	if capacity < 1 {
		t.Fatal("simulation capacity must be positive")
	}
	const tick = 10 * time.Second
	base := time.Date(2026, 8, 22, 17, 0, 0, 0, time.UTC)
	runtimes := simulationRuntimeHints(jobs)
	poller := &Poller{runtimes: runtimes, fastLaneTunings: map[int64]fastLanePolicy{}}
	started := make([]bool, len(jobs))
	queued := make([]bool, len(jobs))
	queue := []int{}
	running := []simulatedRunning{}
	lane := fastLaneState{}
	laneActive := false
	tuning := fastLanePolicy{}
	metrics := simulationMetrics{}

	allFinished := func() bool {
		if len(running) != 0 || len(queue) != 0 {
			return false
		}
		for i := range jobs {
			if !started[i] {
				return false
			}
		}
		return true
	}

	for now := time.Duration(0); now <= 3*time.Hour; now += tick {
		running = slices.DeleteFunc(running, func(item simulatedRunning) bool { return item.finish <= now })
		for i, job := range jobs {
			if !started[i] && !queued[i] && job.arrival <= now {
				queue = append(queue, i)
				queued[i] = true
			}
		}
		if allFinished() {
			return metrics
		}
		remaining := capacity - len(running)
		if remaining <= 0 || len(queue) == 0 {
			continue
		}

		available := make([]crfgithub.AvailableJob, 0, len(queue))
		for _, index := range queue {
			available = append(available, jobs[index].job)
		}

		if !adaptive {
			sort.SliceStable(queue, func(i, j int) bool {
				left, right := jobs[queue[i]], jobs[queue[j]]
				if left.arrival != right.arrival {
					return left.arrival < right.arrival
				}
				return left.id < right.id
			})
			count := min(remaining, len(queue))
			selected := slices.Clone(queue[:count])
			queue = slices.Clone(queue[count:])
			for _, index := range selected {
				queued[index] = false
				started[index] = true
				wait := now - jobs[index].arrival
				if jobs[index].quick {
					metrics.quickWaits = append(metrics.quickWaits, wait)
				} else {
					metrics.longWaits = append(metrics.longWaits, wait)
				}
				finish := now + jobs[index].duration
				running = append(running, simulatedRunning{index: index, finish: finish})
				if finish > metrics.makespan {
					metrics.makespan = finish
				}
			}
			continue
		}

		borrow := false
		if laneActive {
			best := topCandidates("build", available, runtimes, base.Add(now), 1)
			switch {
			case now >= lane.holdUntil.Sub(base):
				borrow = true
				laneActive = false
			case len(best) == 0:
				laneActive = false
			case fastLaneEligible(best[0], lane.longThreshold):
				laneActive = false
			default:
				continue
			}
		}

		batch := crfgithub.MessageBatch{
			Statistics:    &crfgithub.Statistics{TotalAssignedJobs: len(running), TotalAvailableJobs: len(queue)},
			AvailableJobs: available,
		}
		target := deriveFastLanePolicy("build", available, runtimes, len(queue), capacity, base.Add(now))
		tuning = stabilizeFastLanePolicy(tuning, target)
		decision := poller.admissionSelectionWithRuntimes(
			batch, "build", capacity, base.Add(now), borrow, tuning, runtimes,
		)
		if len(decision.requestIDs) == 0 && !decision.reserveFastLane {
			continue
		}
		idToIndex := make(map[int64]int, len(queue))
		for _, index := range queue {
			idToIndex[jobs[index].id] = index
		}
		for _, id := range decision.requestIDs {
			index, ok := idToIndex[id]
			if !ok {
				t.Fatalf("adaptive simulation selected non-queued job %d", id)
			}
			queued[index] = false
			started[index] = true
			wait := now - jobs[index].arrival
			if jobs[index].quick {
				metrics.quickWaits = append(metrics.quickWaits, wait)
			} else {
				metrics.longWaits = append(metrics.longWaits, wait)
			}
			finish := now + jobs[index].duration
			running = append(running, simulatedRunning{index: index, finish: finish})
			if finish > metrics.makespan {
				metrics.makespan = finish
			}
		}
		queue = removeSimulatedQueueIDs(queue, jobs, decision.requestIDs)
		if decision.reserveFastLane {
			lane = fastLaneState{
				capacity: capacity, reservedSlots: decision.policy.reserveSlots,
				holdUntil:    base.Add(now + decision.policy.holdDuration),
				holdDuration: decision.policy.holdDuration, longThreshold: decision.policy.longThreshold,
			}
			laneActive = true
		} else if decision.borrowFastLane {
			laneActive = false
		}
	}
	t.Fatal("admission simulation exceeded three-hour safety bound")
	return simulationMetrics{}
}

func TestSustainedConvoyFastLaneCutsQuickWaitWithBoundedLongDelay(t *testing.T) {
	base := time.Date(2026, 8, 22, 17, 0, 0, 0, time.UTC)
	_ = base
	jobs := make([]simulatedJob, 0, 28)
	for i := 0; i < 8; i++ {
		jobs = append(jobs, simulationJob(base, int64(i+1), 0, 20*time.Minute, false))
	}
	for i := 0; i < 20; i++ {
		jobs = append(jobs, simulationJob(base, int64(100+i), 10*time.Second, 10*time.Second, true))
	}

	fifo := simulateAdmissionWorkload(t, 8, jobs, false)
	adaptive := simulateAdmissionWorkload(t, 8, jobs, true)
	fifoP95 := percentileDuration(fifo.quickWaits, 95)
	adaptiveP95 := percentileDuration(adaptive.quickWaits, 95)
	if adaptiveP95 >= 4*time.Minute {
		t.Fatalf("adaptive quick p95 remained convoy-bound: %s", adaptiveP95)
	}
	if fifoP95 < 19*time.Minute || adaptiveP95*4 >= fifoP95 {
		t.Fatalf("fast lane did not materially improve quick p95: adaptive=%s fifo=%s", adaptiveP95, fifoP95)
	}
	if longest := percentileDuration(adaptive.longWaits, 100); longest > 4*time.Minute {
		t.Fatalf("fast lane delayed a long job beyond bounded convoy tradeoff: %s", longest)
	}
	if adaptive.makespan > fifo.makespan+4*time.Minute {
		t.Fatalf("latency optimization exceeded makespan budget: adaptive=%s fifo=%s", adaptive.makespan, fifo.makespan)
	}
	t.Logf("convoy metrics: quick_p95 adaptive=%s fifo=%s long_max=%s makespan adaptive=%s fifo=%s",
		adaptiveP95, fifoP95, percentileDuration(adaptive.longWaits, 100), adaptive.makespan, fifo.makespan)
}

func TestSustainedQuickStreamCannotStarveLongWorkPastAgingThreshold(t *testing.T) {
	base := time.Date(2026, 8, 22, 17, 0, 0, 0, time.UTC)
	jobs := []simulatedJob{
		simulationJob(base, 1, 0, 20*time.Minute, false),
		simulationJob(base, 2, 0, 20*time.Minute, false),
	}
	for i, arrival := 0, 10*time.Second; arrival <= 12*time.Minute; i, arrival = i+1, arrival+10*time.Second {
		jobs = append(jobs, simulationJob(base, int64(100+i), arrival, 10*time.Second, true))
	}
	adaptive := simulateAdmissionWorkload(t, 2, jobs, true)
	if len(adaptive.longWaits) != 2 {
		t.Fatalf("long jobs missing from simulation: %v", adaptive.longWaits)
	}
	longest := percentileDuration(adaptive.longWaits, 100)
	if longest > queueStarvationAge {
		t.Fatalf("sustained quick stream starved long work: max wait=%s", longest)
	}
	t.Logf("sustained quick-stream metrics: long_max_wait=%s aging_threshold=%s", longest, queueStarvationAge)
}
