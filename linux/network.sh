#!/usr/bin/env bash

ipv4_number() {
  local address=$1 octet number=0
  local -a octets
  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || return 1
    number=$((number * 256 + octet))
  done
  printf '%s\n' "$number"
}

private_ipv4() {
  local number
  number=$(ipv4_number "$1") || return 1
  (( (number & 0xff000000) == 0x0a000000 ||
     (number & 0xfff00000) == 0xac100000 ||
     (number & 0xffff0000) == 0xc0a80000 ))
}

private_ipv4_subnet() {
  local address=${1%/*} prefix=${1##*/} number mask
  [[ "$1" == */* && "$prefix" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || return 1
  private_ipv4 "$address" || return 1
  number=$(ipv4_number "$address")
  mask=$(((0xffffffff << (32 - prefix)) & 0xffffffff))
  (( (number & mask) == number )) || return 1
  case "$address" in
    10.*) (( prefix >= 8 )) ;;
    172.*) (( prefix >= 12 )) ;;
    192.168.*) (( prefix >= 16 )) ;;
  esac
}

auto_private_address() {
  local addresses address selected=
  local -a candidates
  addresses=$(hostname -I) || return 1
  read -r -a candidates <<< "$addresses"
  for address in "${candidates[@]}"; do
    if private_ipv4 "$address"; then
      [[ -z "$selected" || "$selected" == "$address" ]] || return 1
      selected=$address
    fi
  done
  [[ -n "$selected" ]] || return 1
  printf '%s\n' "$selected"
}
