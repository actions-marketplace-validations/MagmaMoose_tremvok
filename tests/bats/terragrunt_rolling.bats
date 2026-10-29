#!/usr/bin/env bats
#
# A rolling stack applies one unit at a time. What it prevents happened: a pull request that
# resized a k3s cluster's three worker VMs was approved, the apply ran the whole plan at once, the
# provider power-cycled all three workers at the same moment, and every workload on the cluster
# went down with them, including the identity provider everyone needed to log in and look.

load helper

setup() {
  setup_common
  cd "$WORK"
  mkdir -p stack out
  export PENDING="${WORK}/pending"
  : >"$PENDING"
  stub sleep

  # A terragrunt that keeps state. $PENDING holds the addresses with changes outstanding. A plan
  # writes the ones it selects to its -out file (all of them, or those under a -target), `show`
  # prints a plan file back, and an apply removes what its plan file held from $PENDING.
  # COUPLED makes a targeted plan select everything, the way tofu pulls in every instance of a
  # resource a target depends on. PULL does the same for one untargeted dependency only, the
  # addresses starting with it. APPEAR adds changes after the first apply, as if the world
  # moved while the roll ran.
  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
printf 'terragrunt %s\n' "$*" >>"${STUB_LOG}"
cmd="$1"; shift
out=""; targets=(); last=""
for a in "$@"; do
  case "$a" in
    -out=*) out="${a#-out=}" ;;
    -target=*) targets+=( "${a#-target=}" ) ;;
  esac
  last="$a"
done
case "$cmd" in
  init) exit 0 ;;
  show) cat "$last"; exit 0 ;;
  plan)
    : >"$out"
    while IFS= read -r addr; do
      [ -n "$addr" ] || continue
      keep=0
      if [ "${#targets[@]}" -eq 0 ] || [ -n "${COUPLED:-}" ]; then keep=1; fi
      if [ -n "${PULL:-}" ]; then case "$addr" in "$PULL"*) keep=1 ;; esac; fi
      for t in "${targets[@]}"; do
        case "$addr" in "$t"*) keep=1 ;; esac
      done
      if [ "$keep" -eq 1 ]; then printf '  # %s will be updated in-place\n' "$addr" >>"$out"; fi
    done <"$PENDING"
    cat "$out"
    if [ -s "$out" ]; then exit 2; fi
    exit 0 ;;
  apply)
    sed -nE 's/^.*# (.+) will be updated in-place$/\1/p' "$last" >"${PENDING}.applied"
    grep -vxF -f "${PENDING}.applied" "$PENDING" >"${PENDING}.next" || true
    mv "${PENDING}.next" "$PENDING"
    if [ -n "${APPEAR:-}" ] && [ ! -f "${PENDING}.appeared" ]; then
      : >"${PENDING}.appeared"
      printf '%s\n' "$APPEAR" | tr ' ' '\n' >>"$PENDING"
    fi
    printf 'Apply complete.\n'; exit 0 ;;
esac
exit 0
STUBEOF
}

pending() { printf '%s\n' "$@" >"$PENDING"; }

# What the plan run left behind: a saved plan of everything pending.
saved_plan() {
  local a
  for a in "$@"; do printf '  # %s will be updated in-place\n' "$a"; done >out/plan.tfplan
}

roll() {
  TG_ROLLING="${TG_ROLLING:-module.node}" TG_ROLLING_PAUSE="${TG_ROLLING_PAUSE:-7}" \
    run bash "${SCRIPTS}/terragrunt-run.sh" apply stack out
}

targets_in_order() { grep -oE -- '-target=[^ ]+' "$STUB_LOG" | tr '\n' ' '; }

@test "three changed units are applied one at a time, in plan order, with the pause between them" {
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this' 'module.node["c"].vcd_vm.this'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this' 'module.node["c"].vcd_vm.this'
  roll
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "applied" ]
  [ "$(targets_in_order)" = '-target=module.node["a"] -target=module.node["b"] -target=module.node["c"] ' ]
  [ "$(grep -c '^terragrunt apply' "$STUB_LOG")" -eq 3 ]
  [ "$(grep -c '^sleep 7$' "$STUB_LOG")" -eq 2 ]
  [ ! -s "$PENDING" ]
  [[ "$output" == *"ROLLING: 3 units of stack change"* ]]
}

@test "the saved plan is never applied in one go when it changes several units" {
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  roll
  [ "$status" -eq 0 ]
  refute grep -q 'terragrunt apply .*out/plan.tfplan' "$STUB_LOG"
}

@test "each unit waits out the pause before it is planned, so its plan reads the state it is applied to" {
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  roll
  [ "$status" -eq 0 ]
  # sleep, then the second unit's plan: never a plan made a pause ago.
  [ "$(grep -A1 '^sleep' "$STUB_LOG" | tail -1 | grep -c 'target=module.node\["b"\]')" -eq 1 ]
}

@test "a unit whose targeted plan also changes another unit is refused before any of it is applied" {
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  COUPLED=1 roll
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
  refute grep -q '^terragrunt apply' "$STUB_LOG"
  [[ "$output" == *'["a"] cannot be applied on its own'* ]]
  [[ "$output" == *'module.node["b"].vcd_vm.this'* ]]
}

@test "one changed unit is not a roll: the saved plan is applied as it was reviewed" {
  pending 'module.node["a"].vcd_vm.this' 'random_password.admin'
  saved_plan 'module.node["a"].vcd_vm.this' 'random_password.admin'
  roll
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "applied" ]
  grep -q 'terragrunt apply .*out/plan.tfplan' "$STUB_LOG"
  refute grep -q -- '-target=' "$STUB_LOG"
  refute grep -q '^sleep' "$STUB_LOG"
}

@test "without terragrunt-rolling the plan is never read back, and applies as before" {
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  run bash "${SCRIPTS}/terragrunt-run.sh" apply stack out
  [ "$status" -eq 0 ]
  refute grep -q '^terragrunt show' "$STUB_LOG"
  grep -q 'terragrunt apply .*out/plan.tfplan' "$STUB_LOG"
}

@test "changes outside every unit are applied by the full plan at the end" {
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this' 'vcd_network.cluster'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this' 'vcd_network.cluster'
  roll
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "applied" ]
  [ "$(grep -c '^terragrunt apply' "$STUB_LOG")" -eq 3 ]
  grep '^terragrunt apply' "$STUB_LOG" | tail -1 | grep -q 'out/plan.tfplan'
  [ ! -s "$PENDING" ]
}

@test "units an interrupted run already applied are skipped, and a skip waits for nothing" {
  pending 'module.node["c"].vcd_vm.this'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this' 'module.node["c"].vcd_vm.this'
  roll
  [ "$status" -eq 0 ]
  [ "$(grep -c '^terragrunt apply' "$STUB_LOG")" -eq 1 ]
  refute grep -q '^sleep' "$STUB_LOG"
  [[ "$output" == *'["a"] has nothing left to change'* ]]
}

@test "changes to several units that appear during the roll are refused, not applied together" {
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  APPEAR='module.node["d"].vcd_vm.this module.node["e"].vcd_vm.this' roll
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
  [ "$(grep -c '^terragrunt apply' "$STUB_LOG")" -eq 2 ]
  [[ "$output" == *"still changes several units at once"* ]]
}

@test "instances of two addresses that share a key are one unit, and are targeted together" {
  pending 'module.node["a"].vcd_vm.this' 'disk.data["a"]' 'module.node["b"].vcd_vm.this' 'disk.data["b"]'
  saved_plan 'module.node["a"].vcd_vm.this' 'disk.data["a"]' 'module.node["b"].vcd_vm.this' 'disk.data["b"]'
  TG_ROLLING='module.node disk.data' roll
  [ "$status" -eq 0 ]
  [ "$(targets_in_order)" = '-target=module.node["a"] -target=disk.data["a"] -target=module.node["b"] -target=disk.data["b"] ' ]
  [ "$(grep -c '^sleep' "$STUB_LOG")" -eq 1 ]
}

@test "a unit is targeted under every address, even one it has no instance under" {
  # A control-plane node with no data disk. Targeted as module.node["cp"] alone, tofu plans
  # every instance of the disk resource it depends on, so every worker's disk resize lands with
  # the control plane. disk.data["cp"] names nothing, and keeps them out.
  pending 'module.node["cp"].vcd_vm.this' 'module.node["w"].vcd_vm.this' 'disk.data["w"]'
  saved_plan 'module.node["cp"].vcd_vm.this' 'module.node["w"].vcd_vm.this' 'disk.data["w"]'
  TG_ROLLING='module.node disk.data' roll
  [ "$status" -eq 0 ]
  [ "$(targets_in_order)" = '-target=module.node["cp"] -target=disk.data["cp"] -target=module.node["w"] -target=disk.data["w"] ' ]
}

@test "an unlisted per-unit resource another unit's plan pulls in is refused, by its key" {
  # The disks are nobody's unit, because only module.node is listed, but each is keyed like one.
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this' 'disk.data["a"]' 'disk.data["b"]'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this' 'disk.data["a"]' 'disk.data["b"]'
  PULL='disk.data' roll
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
  refute grep -q '^terragrunt apply' "$STUB_LOG"
  [[ "$output" == *'disk.data["b"]'* ]]
  [[ "$output" == *"add its block to terragrunt-rolling"* ]]
}

@test "a shared dependency a unit's plan pulls in is applied with it" {
  pending 'vcd_network.cluster' 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  saved_plan 'vcd_network.cluster' 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  PULL='vcd_network' roll
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "applied" ]
  [ "$(grep -c '^terragrunt apply' "$STUB_LOG")" -eq 2 ]
  [ ! -s "$PENDING" ]
}

@test "count instances are units too" {
  pending 'module.node[0].vcd_vm.this' 'module.node[1].vcd_vm.this'
  saved_plan 'module.node[0].vcd_vm.this' 'module.node[1].vcd_vm.this'
  roll
  [ "$status" -eq 0 ]
  [ "$(targets_in_order)" = '-target=module.node[0] -target=module.node[1] ' ]
}

@test "a prefix that only starts another block's name is not that block" {
  # module.nodes["a"] is not an instance of module.node.
  pending 'module.nodes["a"].vcd_vm.this' 'module.nodes["b"].vcd_vm.this'
  saved_plan 'module.nodes["a"].vcd_vm.this' 'module.nodes["b"].vcd_vm.this'
  roll
  [ "$status" -eq 0 ]
  refute grep -q -- '-target=' "$STUB_LOG"
  grep -q 'terragrunt apply .*out/plan.tfplan' "$STUB_LOG"
}

@test "the read-back counts action lines only, through terragrunt's log prefix" {
  # Drift notes and data-source reads are not changes; a tainted or deposed object is.
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this' 'module.node["c"].vcd_vm.this'
  cat >out/plan.tfplan <<'PLAN'
12:00:00.000 STDOUT tofu: Note: Objects have changed outside of OpenTofu
12:00:00.000 STDOUT tofu:   # module.node["z"].vcd_vm.this has changed
12:00:00.000 STDOUT tofu:   # module.node["y"].data.vcd_catalog.this will be read during apply
12:00:00.000 STDOUT tofu:   # module.node["a"].vcd_vm.this will be updated in-place
12:00:00.000 STDOUT tofu:       # (31 unchanged attributes hidden)
12:00:00.000 STDOUT tofu:   # module.node["b"].vcd_vm.this is tainted, so must be replaced
12:00:00.000 STDOUT tofu:   # module.node["c"].vcd_vm.this (deposed object 1a2b3c4d) will be destroyed
PLAN
  roll
  [ "$status" -eq 0 ]
  [ "$(targets_in_order)" = '-target=module.node["a"] -target=module.node["b"] -target=module.node["c"] ' ]
}

@test "a rolling apply with no saved plan plans first, then rolls" {
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  roll
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "applied" ]
  [[ "$output" == *"no saved plan"* ]]
  [ "$(targets_in_order)" = '-target=module.node["a"] -target=module.node["b"] ' ]
}

@test "a rolling apply with nothing to change says so and applies nothing" {
  roll
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "no-changes" ]
  refute grep -q '^terragrunt apply' "$STUB_LOG"
}

@test "every plan and apply of a roll takes the state lock" {
  pending 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  saved_plan 'module.node["a"].vcd_vm.this' 'module.node["b"].vcd_vm.this'
  TG_STATE_LOCK=false roll
  [ "$status" -eq 0 ]
  refute grep -q -- '-lock=false' "$STUB_LOG"
  [ "$(grep -E '^terragrunt (plan|apply)' "$STUB_LOG" | grep -vc -- '-lock-timeout=5m')" -eq 0 ]
}
