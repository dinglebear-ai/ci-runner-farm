// Command ci-runner-github-app keeps a current GitHub App installation token:
// ci-runner-github-app github-app-token <app-id> <installation-id> <private-key-file> <token-file>.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/unraid/ci-runner-farm/pkg/githubapp"
)

func main() {
	if len(os.Args) != 6 || os.Args[1] != "github-app-token" {
		fmt.Fprintln(os.Stderr, "usage: ci-runner-github-app github-app-token <app-id> <installation-id> <private-key-file> <token-file>")
		os.Exit(2)
	}
	if err := runGitHubAppToken(os.Args[2:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "ci-runner-github-app:", err)
		os.Exit(1)
	}
}

// The token file has its own lock, so minting needs no fleet lock.
func runGitHubAppToken(arguments []string, output io.Writer) error {
	appID, appErr := strconv.ParseInt(arguments[0], 10, 64)
	installationID, installationErr := strconv.ParseInt(arguments[1], 10, 64)
	if appErr != nil || installationErr != nil {
		return errors.New("github-app-token requires numeric app and installation ids")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	minter := githubapp.Minter{AppID: appID, InstallationID: installationID, KeyPath: arguments[2], TokenPath: arguments[3]}
	minted, err := minter.Ensure(ctx)
	if err != nil {
		return err
	}
	state := "current"
	if minted {
		state = "minted"
	}
	_, err = fmt.Fprintln(output, state)
	return err
}
