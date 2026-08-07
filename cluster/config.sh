#!/usr/bin/env bash
# Cluster-side configuration for drac-opencode. Source from other cluster
# scripts. Every value can be overridden with an environment variable.

: "${PORT:=11434}"
: "${GPU_COUNT:=1}"
: "${CPUS:=4}"
: "${MEM:=24G}"
: "${TIME:=24:00:00}"
: "${MODEL:=qwen3:14b}"
: "${SESSION:=opencode}"
: "${CONFIG_BASE:=${SCRATCH:-/scratch/$USER}/opencode}"

CONFIG_SIF="${CONFIG_SIF:-$CONFIG_BASE/ollama.sif}"
CONFIG_MODELS="${CONFIG_MODELS:-$CONFIG_BASE/models}"
CONFIG_STATUS="${CONFIG_STATUS:-$CONFIG_BASE/status.txt}"
CONFIG_LOG="${CONFIG_LOG:-$CONFIG_BASE/ollama.log}"

export PORT GPU_COUNT CPUS MEM TIME MODEL SESSION
export CONFIG_BASE CONFIG_SIF CONFIG_MODELS CONFIG_STATUS CONFIG_LOG
