#!/usr/bin/env bash

: "${CRF_FAKE_NOW:=1700000000}"

crf_clock_now() {
  printf '%s\n' "$CRF_FAKE_NOW"
}

crf_clock_advance() {
  CRF_FAKE_NOW=$((CRF_FAKE_NOW + $1))
  export CRF_FAKE_NOW
}
