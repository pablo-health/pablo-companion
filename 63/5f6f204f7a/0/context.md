# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: CI/CD, Make Repo Public, Windows Epics

## Context

AudioCaptureKit (the reference repo) has a full production CI/CD setup with 5 GitHub Actions workflows, dependabot, and CODEOWNERS. The user wants pablo-companion to match that setup. The repo is currently a skeleton — the macOS app builds, but there are no tests and no Rust core yet. We'll mirror the AudioCaptureKit structure, using path filters so Rust jobs only trigger once `core/` exists.

Additiona...

### Prompt 2

[Request interrupted by user for tool use]

### Prompt 3

let's get it right from the start :-)

