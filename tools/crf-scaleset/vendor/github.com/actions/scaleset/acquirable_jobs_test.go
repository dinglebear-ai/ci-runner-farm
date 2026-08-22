package scaleset

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func acquirableTestClient(server *httptest.Server) *Client {
	return &Client{
		actionsServiceURL:                 server.URL,
		actionsServiceAdminToken:          "admin-token",
		actionsServiceAdminTokenExpiresAt: time.Now().Add(time.Hour),
		commonClient:                      commonClient{httpClient: server.Client(), userAgent: "crf-contract-test"},
	}
}

func TestGetAcquirableJobsHTTPContract(t *testing.T) {
	queued := "2026-08-21T06:30:00Z"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/_apis/runtime/runnerscalesets/74/acquirablejobs" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		if got := r.URL.Query().Get("api-version"); got != "6.0-preview" {
			t.Errorf("unexpected api-version: %q", got)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer admin-token" {
			t.Errorf("unexpected authorization: %q", got)
		}
		fmt.Fprintf(w, `{"count":1,"value":[{"runnerRequestId":101,"ownerName":"dinglebear-ai","repositoryName":"soma","jobDisplayName":"unit","queueTime":%q}]}`, queued)
	}))
	defer server.Close()

	jobs, err := acquirableTestClient(server).GetAcquirableJobs(context.Background(), 74)
	if err != nil {
		t.Fatal(err)
	}
	if len(jobs) != 1 || jobs[0].RunnerRequestID != 101 || jobs[0].OwnerName != "dinglebear-ai" ||
		jobs[0].RepositoryName != "soma" || jobs[0].JobDisplayName != "unit" ||
		!jobs[0].QueueTime.Equal(time.Date(2026, 8, 21, 6, 30, 0, 0, time.UTC)) {
		t.Fatalf("metadata/time decoding changed: %#v", jobs)
	}
}

func TestGetAcquirableJobsEmptyErrorAndBodyFuses(t *testing.T) {
	for _, tc := range []struct {
		name      string
		status    int
		body      string
		wantEmpty bool
		wantError string
		wantTyped bool
	}{
		{name: "no-content", status: http.StatusNoContent, wantEmpty: true},
		{name: "typed-error", status: http.StatusConflict, body: `{"typeName":"AgentExistsException","message":"conflict"}`, wantError: "conflict", wantTyped: true},
		{name: "malformed", status: http.StatusOK, body: `{"count":1,"value":[`, wantError: "failed to decode acquirable jobs"},
		{name: "oversized", status: http.StatusOK, body: strings.Repeat(" ", maxAcquirableJobsResponseBytes+1), wantError: "exceeds"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer server.Close()
			jobs, err := acquirableTestClient(server).GetAcquirableJobs(context.Background(), 1)
			if tc.wantEmpty {
				if err != nil || len(jobs) != 0 {
					t.Fatalf("expected empty success: jobs=%v err=%v", jobs, err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantError) {
				t.Fatalf("unexpected error: %v", err)
			}
			if tc.wantTyped && !errors.Is(err, RunnerExistsError) {
				t.Fatalf("typed error was lost: %v", err)
			}
		})
	}
}

func TestGetAcquirableJobsHonorsCanceledAndDeadlineContexts(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer server.Close()
	client := acquirableTestClient(server)

	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := client.GetAcquirableJobs(canceled, 1); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled context was lost: %v", err)
	}
	deadline, stop := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer stop()
	if _, err := client.GetAcquirableJobs(deadline, 1); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("deadline context was lost: %v", err)
	}
}
