package ipc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"

	"github.com/jmagar/ci-runner-farm/tools/crf-scaleset/internal/protocol"
)

type Client struct {
	Path string
}

func (c Client) Call(ctx context.Context, request protocol.Request) (protocol.Response, error) {
	if c.Path == "" {
		return protocol.Response{}, errors.New("socket_path_required")
	}
	if err := request.Validate(); err != nil {
		return protocol.Response{}, err
	}
	var frame bytes.Buffer
	if err := json.NewEncoder(&frame).Encode(request); err != nil {
		return protocol.Response{}, err
	}
	if frame.Len() > protocol.MaxFrameBytes {
		return protocol.Response{}, errors.New("frame_too_large")
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", c.Path)
	if err != nil {
		return protocol.Response{}, err
	}
	defer conn.Close()
	if _, err := conn.Write(frame.Bytes()); err != nil {
		return protocol.Response{}, err
	}
	if unix, ok := conn.(*net.UnixConn); ok {
		if err := unix.CloseWrite(); err != nil {
			return protocol.Response{}, err
		}
	}
	data, err := io.ReadAll(io.LimitReader(conn, protocol.MaxFrameBytes+1))
	if err != nil {
		return protocol.Response{}, err
	}
	if len(data) > protocol.MaxFrameBytes {
		return protocol.Response{}, errors.New("response_too_large")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var response protocol.Response
	if err := dec.Decode(&response); err != nil {
		return protocol.Response{}, err
	}
	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		return protocol.Response{}, errors.New("response_trailing_data")
	}
	if response.SchemaVersion != protocol.SchemaVersion || response.RequestID != request.RequestID {
		return protocol.Response{}, errors.New("response_identity_mismatch")
	}
	return response, nil
}
