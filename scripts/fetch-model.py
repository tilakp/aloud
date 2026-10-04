#!/usr/bin/env python3
"""Fetches the Kokoro voice model into Model/, which Xcode copies into the app.

Runs as a pre-build step. Every file comes from a fixed Hugging Face commit
and must match the SHA-256 in scripts/model-files.tsv, or the build fails.
Files already in Model/ with the right checksum are skipped, so only the
first build downloads anything (~110MB).

The paths match FluidAudio's cache layout (~/.cache/fluidaudio/Models), which
is where the app copies them at launch. English voice packs other than
af_heart are published only as voices/<name>.json; they are converted here to
the flat fp32 .bin layout FluidAudio uses (the same conversion as its
KokoroAneVoicePack.load(fromJSON:)).

    scripts/fetch-model.py                 fetch and verify (the build step)
    scripts/fetch-model.py --repin <rev>   re-pin model-files.tsv to commit <rev>
"""
import hashlib
import json
import os
import struct
import subprocess
import sys

REPO = "FluidInference/kokoro-82m-coreml"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILE_LIST = os.path.join(ROOT, "scripts", "model-files.tsv")
OUTPUT = os.path.join(ROOT, "Model")


def fail(message):
    print(f"error: {message}", file=sys.stderr)  # Xcode shows "error:" lines as build errors
    sys.exit(1)


def read_list():
    revision, entries = None, []
    for line in open(FILE_LIST):
        if line.startswith("# revision "):
            revision = line.split()[2]
        elif line.strip() and not line.startswith("#"):
            sha256, path = line.rstrip("\n").split("\t")
            entries.append((sha256, path))
    return revision, entries


def source_for(path):
    """The repo path a cache path comes from, and whether it is a JSON voice."""
    if path.startswith("kokoro-82m-coreml/ANE/"):
        name = path.removeprefix("kokoro-82m-coreml/ANE/")
        if "/" not in name and name.endswith(".bin") and name != "af_heart.bin":
            return f"voices/{name.removesuffix('.bin')}.json", True
        return f"ANE/{name}", False
    return path.removeprefix("kokoro/"), False


def download(revision, repo_path):
    url = f"https://huggingface.co/{REPO}/resolve/{revision}/{repo_path}"
    result = subprocess.run(["curl", "-sfL", "--retry", "3", url], capture_output=True)
    if result.returncode != 0:
        fail(f"could not download {url}")
    return result.stdout


def voice_json_to_bin(data):
    voice = json.loads(data)
    rows = [voice[str(row)] for row in range(1, 511)]
    if any(len(row) != 256 for row in rows):
        fail("voice JSON rows must hold 256 numbers")
    return b"".join(struct.pack("<256f", *row) for row in rows)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def write(path, data):
    destination = os.path.join(OUTPUT, path)
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    with open(destination, "wb") as out:
        out.write(data)


def fetch():
    revision, entries = read_list()
    fetched = 0
    for expected, path in entries:
        existing = os.path.join(OUTPUT, path)
        if os.path.exists(existing) and sha256(open(existing, "rb").read()) == expected:
            continue
        repo_path, is_voice = source_for(path)
        data = download(revision, repo_path)
        if is_voice:
            data = voice_json_to_bin(data)
        if sha256(data) != expected:
            fail(f"{path} from {REPO}@{revision} does not match model-files.tsv")
        write(path, data)
        fetched += 1
    # The app checks its cache against this list at launch.
    write("files.tsv", open(FILE_LIST, "rb").read())
    print(f"Voice model: {len(entries)} files verified, {fetched} downloaded")


def repin(revision):
    """Checks each download against Hugging Face's own hashes (LFS SHA-256 or
    git blob hash) at <revision>, then records the new checksums."""
    _, entries = read_list()
    tree_url = f"https://huggingface.co/api/models/{REPO}/tree/{revision}?recursive=true"
    tree = json.loads(subprocess.run(["curl", "-sf", tree_url], check=True, capture_output=True).stdout)
    remote = {item["path"]: item for item in tree if item["type"] == "file"}

    lines = []
    for _, path in entries:
        repo_path, is_voice = source_for(path)
        item = remote.get(repo_path) or fail(f"{repo_path} is not in {REPO}@{revision}")
        data = download(revision, repo_path)
        blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        if (item["lfs"]["oid"] if "lfs" in item else item["oid"]) not in (sha256(data), blob):
            fail(f"{repo_path} does not match the Hugging Face tree at {revision}")
        if is_voice:
            data = voice_json_to_bin(data)
        write(path, data)
        lines.append(f"{sha256(data)}\t{path}")

    with open(FILE_LIST, "w") as out:
        out.write(f"# revision {revision}\n")
        out.write("# sha256\tpath under ~/.cache/fluidaudio/Models (and the app's Model/ folder)\n")
        out.write("\n".join(lines) + "\n")
    print(f"Re-pinned {len(lines)} files to {REPO}@{revision}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--repin"] and len(sys.argv) == 3:
        repin(sys.argv[2])
    elif len(sys.argv) == 1:
        fetch()
    else:
        fail(__doc__)
