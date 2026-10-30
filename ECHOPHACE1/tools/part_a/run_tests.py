#!/usr/bin/env python3
"""Portable Linux/Ed Part A verification; no hardware or whole-project R6 claim.

Requires Python3 with NumPy/Pillow, Verilator (tested baseline 5.050), make and a
C++ compiler. Run from any directory. Every invocation creates a fresh work
directory; the original RTL and course sources are never modified.
"""
# ECHO-7 Part A | Human owner: Member A (name/SID pending).
# AI-assisted by OpenAI Codex; human review required before submission.
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
CORE = [
    "rtl/part_a/part_a_pkg.sv",
    "rtl/part_a/causalMaskCleanup.sv",
    "rtl/echo7/unsignedDivider.sv",
    "rtl/part_a/rawColourCentroid.sv",
    "rtl/part_a/boundedCandidates.sv",
]
PIPELINE = [
    "rtl/camera_pkg.sv",
    "rtl/echo7/rgbFixedSeg.sv",
    "rtl/echo7/rgbRatioSeg.sv",
    "rtl/echo7/hsvSeg.sv",
    "rtl/echo7/segmentationSelector.sv",
    *CORE,
    "rtl/part_a/partACapturePipeline.sv",
    "rtl/snapshot_ram.sv",
    "rtl/snapshot_probes.sv",
    "rtl/frame_snap.sv",
]
PIPELINE_BENCH = ("tb/part_a/partACapturePipeline_tb.sv"
                  if (ROOT / "tb/part_a/partACapturePipeline_tb.sv").is_file()
                  else "tb/partACapturePipeline_tb.sv")
BENCHES = [
    ("cleanup_centroid_tb", CORE, "tb/part_a/cleanup_centroid_tb.sv", "PASS cleanup_centroid_tb:"),
    ("boundedCandidates_tb", CORE, "tb/part_a/boundedCandidates_tb.sv", "PASS boundedCandidates:"),
    ("partACapturePipeline_tb", PIPELINE, PIPELINE_BENCH, "PASS partACapturePipeline:"),
]


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class VerificationFailure(RuntimeError):
    pass


class Runner:
    def __init__(self, args):
        self.args = args
        self.started = time.monotonic()
        self.deadline = self.started + args.timeout
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
        self.out = args.work_root.resolve() / ("part_a_tests_" + stamp)
        self.out.mkdir(parents=True, exist_ok=False)
        self.summary = {
            "schema": "echo-parta-portable-verification-v2",
            "status": "RUNNING",
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "scope": "Part A Python models/checker, cleanup/raw centroid, bounded candidates and native capture front end only; not whole-project R6 compliance",
            "hardware_executed": False,
            "source_root": str(ROOT),
            "output_directory": str(self.out),
            "overall_timeout_seconds": args.timeout,
            "compile_jobs": args.jobs,
            "verilator_tested_baseline": "5.050",
            "steps": [],
            "source_sha256": {},
            "mutation": {"status": "NOT_RUN"},
        }
        self.write_summary()

    def write_summary(self):
        self.summary["elapsed_seconds"] = round(time.monotonic() - self.started, 3)
        (self.out / "summary.json").write_text(json.dumps(self.summary, indent=2) + "\n", encoding="utf-8")

    def run(self, name, command, *, allow_failure=False):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise VerificationFailure("300-second overall budget exhausted" if self.args.timeout == 300 else "overall timeout exhausted")
        log_path = self.out / (name + ".log")
        step = {"name": name, "command": [str(c) for c in command], "cwd": str(ROOT), "log": str(log_path)}
        self.summary["steps"].append(step)
        step_start = time.monotonic()
        print(f"[{name}] {shlex.join(step['command'])}", flush=True)
        with log_path.open("w", encoding="utf-8") as log:
            log.write("COMMAND_JSON " + json.dumps(step["command"]) + "\nCWD " + str(ROOT) + "\n")
            log.flush()
            process = subprocess.Popen(step["command"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=(os.name == "posix"))
            try:
                code = process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.wait()
                step.update(status="TIMEOUT", elapsed_seconds=round(time.monotonic()-step_start, 3))
                self.write_summary()
                raise VerificationFailure(f"overall timeout during {name}; see {log_path}")
            except KeyboardInterrupt:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.wait()
                step.update(status="INTERRUPTED", elapsed_seconds=round(time.monotonic()-step_start, 3))
                self.write_summary()
                raise
        output = log_path.read_text(encoding="utf-8", errors="replace")
        step.update(returncode=code, status="PASS" if code == 0 else "NONZERO",
                    elapsed_seconds=round(time.monotonic()-step_start, 3))
        self.write_summary()
        if code and not allow_failure:
            raise VerificationFailure(f"{name} exited {code}; see {log_path}")
        return code, output, step

    def build(self, name, top, sources, bench):
        build_dir = self.out / name
        build_dir.mkdir()
        binary = build_dir / "sim"
        command = [self.args.verilator, "--binary", "--timing", "--assert", "-Wno-fatal",
                   "-j", str(self.args.jobs), "--top-module", top,
                   "--Mdir", str(build_dir / "obj"), "-o", str(binary)]
        command += [str(Path(p).resolve()) for p in [*sources, bench]]
        # Compilation must succeed even for the intentional mutation. A build
        # failure is infrastructure/design failure, never evidence of detection.
        self.run(name + "_build", command)
        if not binary.is_file():
            raise VerificationFailure(f"Verilator returned success without expected executable {binary}")
        return binary

    def execute(self):
        required = {p for _, sources, bench, _ in BENCHES for p in [*sources, bench]}
        required |= {str(p.relative_to(ROOT)) for p in (ROOT / "tools/part_a").glob("*.py")}
        required.add("run_part_a_tests.sh")
        missing = sorted(p for p in required if not (ROOT / p).is_file())
        if missing:
            raise VerificationFailure("missing canonical sources: " + ", ".join(missing))
        self.summary["source_sha256"] = {p: sha256(ROOT / p) for p in sorted(required)}
        self.write_summary()
        _, version, _ = self.run("verilator_version", [self.args.verilator, "--version"])
        self.summary["verilator_version_output"] = version.splitlines()[-1]
        self.run("python_tests", [sys.executable, "-m", "unittest", "discover", "-s",
                                  str(ROOT / "tools/part_a"), "-p", "test_*.py", "-v"])
        vectors = self.out / "vectors"
        self.run("generate_vectors", [sys.executable, str(ROOT / "tools/part_a/candidates_reclaimed_model.py"),
                                      "--write-vectors", str(vectors)])
        vector_metadata = json.loads((vectors / "metadata.json").read_text(encoding="utf-8"))
        expected_vector_contract = {
            "schema": "echo-candidates-row-reclaimed-v2", "case_count": 18,
            "width": 320, "height": 240, "cap": 8, "min_area": 3,
            "expected_words_per_case": 134,
        }
        if any(vector_metadata.get(key) != value for key, value in expected_vector_contract.items()):
            raise VerificationFailure("reference vectors do not match the 18-case V2 bench contract")
        self.summary["vector_contract"] = expected_vector_contract
        self.summary["vector_sha256"] = {p.name: sha256(p) for p in sorted(vectors.iterdir()) if p.is_file()}
        for top, sources, bench, marker in BENCHES:
            binary = self.build(top, top, [ROOT / p for p in sources], ROOT / bench)
            command = [str(binary)]
            if top == "boundedCandidates_tb":
                command.append("+VECTORS=" + str(vectors))
            _, output, _ = self.run(top + "_simulation", command)
            if marker not in output:
                raise VerificationFailure(f"{top} returned zero without its expected PASS marker")

        original = ROOT / "rtl/part_a/boundedCandidates.sv"
        needle = "c.cx=9'((int'(a.xmin)+int'(a.xmax))/2);"
        replacement = "c.cx=9'(((int'(a.xmin)+int'(a.xmax))/2)+1);"
        original_text = original.read_text(encoding="utf-8")
        if original_text.count(needle) != 1:
            raise VerificationFailure("mutation anchor is absent/ambiguous; update the explicit cx+1 mutation")
        mutation_dir = self.out / "mutated_source"
        mutation_dir.mkdir()
        mutated = mutation_dir / "boundedCandidates.sv"
        mutated.write_text(original_text.replace(needle, replacement), encoding="utf-8")
        self.summary["mutation"].update(
            description="Deliberately add one to candidate bounding-box cx; temporary source copy only",
            original_sha256=sha256(original), mutated_sha256=sha256(mutated), source=str(mutated))
        mutant_sources = [mutated if p == "rtl/part_a/boundedCandidates.sv" else ROOT / p for p in CORE]
        binary = self.build("cx_plus_one_mutation", "boundedCandidates_tb", mutant_sources,
                            ROOT / "tb/part_a/boundedCandidates_tb.sv")
        code, output, step = self.run("cx_plus_one_mutation_simulation",
                                     [str(binary), "+VECTORS=" + str(vectors)], allow_failure=True)
        # Require the intended independently expected x-centre mismatch. A crash,
        # loader problem, assertion elsewhere or compiler error cannot be CAUGHT.
        mismatch = re.search(r"FAIL case0 colour0 candidate0 field6 got\d+ expected\d+", output)
        if code == 0 or not mismatch:
            self.summary["mutation"]["status"] = "NOT_CAUGHT"
            raise VerificationFailure("cx+1 mutation did not fail with expected case0/candidate0/field6 mismatch")
        step["status"] = "CAUGHT"
        self.summary["mutation"].update(status="CAUGHT", evidence=mismatch.group(0), returncode=code)
        changed = [p for p, digest in self.summary["source_sha256"].items() if sha256(ROOT / p) != digest]
        if changed:
            raise VerificationFailure("canonical sources changed during run: " + ", ".join(changed))
        self.summary["canonical_sources_unchanged"] = True
        self.summary["status"] = "PASS"
        self.write_summary()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", default=os.environ.get("VERILATOR", "verilator"),
                        help="standard Verilator CLI executable (no Windows wheel workaround)")
    parser.add_argument("--timeout", type=float, default=300, help="overall seconds for all checks, default 300")
    parser.add_argument("--jobs", type=int, default=4, help="parallel Verilator build jobs, default 4")
    parser.add_argument("--work-root", type=Path, default=ROOT / "work", help="parent of a fresh timestamped run directory")
    args = parser.parse_args()
    if args.timeout <= 0 or args.jobs < 1:
        parser.error("--timeout must be positive and --jobs at least 1")
    if os.name == "posix":
        # The expected mutation assertion can abort. Keep any core dump out of
        # the source tree; child compilers/simulators inherit this process limit.
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    runner = Runner(args)
    try:
        executable = shutil.which(args.verilator)
        if executable is None:
            raise VerificationFailure(f"Verilator CLI not found: {args.verilator}; install/use the Linux/Ed toolchain")
        args.verilator = executable
        runner.execute()
    except (VerificationFailure, OSError, KeyboardInterrupt) as exc:
        runner.summary.update(status="FAIL", error=str(exc) or "interrupted")
        runner.write_summary()
        print(f"FAIL: {exc}\nSummary: {runner.out / 'summary.json'}", file=sys.stderr)
        return 1
    print(f"PASS: Part A modules/front end; deliberate cx+1 mutation CAUGHT.\nSummary: {runner.out / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
