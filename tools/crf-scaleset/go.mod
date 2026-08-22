module github.com/dinglebear-ai/ci-runner-farm/tools/crf-scaleset

go 1.25.3

require github.com/actions/scaleset v0.4.0

replace github.com/actions/scaleset => github.com/dinglebear-ai/scaleset v0.4.1-0.20260822022511-958c47c4357d

require (
	github.com/golang-jwt/jwt/v4 v4.5.2 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/hashicorp/go-cleanhttp v0.5.2 // indirect
	github.com/hashicorp/go-retryablehttp v0.7.8 // indirect
)
