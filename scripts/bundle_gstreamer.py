#!/usr/bin/env python3
"""Copy the GStreamer pieces AirPlay Splitter uses into an app bundle and make
them self-contained (no Homebrew needed at runtime).

    python3 scripts/bundle_gstreamer.py "<App>.app"

Layout inside Contents/Resources/gst:
    bin/gst-launch-1.0, bin/gst-inspect-1.0   (doubletake runs these)
    libexec/gst-plugin-scanner
    lib/*.dylib                                (GStreamer, GLib, FFmpeg, ...)
    lib/gstreamer-1.0/*.dylib                  (plugins)
Contents/Helpers/receiver/AirPlay Splitter (UxPlay) is relinked against lib/ as well.

Every Homebrew reference is rewritten to @rpath/<name>. Signatures are
invalidated by install_name_tool, so the caller must re-sign afterwards.
"""
import os
import shutil
import subprocess
import sys

BREW = subprocess.run(["brew", "--prefix"], capture_output=True, text=True).stdout.strip() or "/opt/homebrew"
GST = subprocess.run(["brew", "--prefix", "gstreamer"], capture_output=True, text=True).stdout.strip()

PLUGINS = [
    # transport and RTP
    "coreelements", "udp", "rtp", "rtpmanager", "rtponvif",
    # video: parse, decode, convert, encode (VideoToolbox lives in applemedia)
    "videoparsersbad", "applemedia", "playback", "typefindfunctions",
    "videoconvertscale", "videorate", "jpeg", "libav",
    # audio
    "audioconvert", "audioresample", "audiorate", "audiobuffersplit", "audioparsers", "volume",
    # sinks and app glue UxPlay expects
    "app", "autodetect", "osxaudio", "osxvideo",
]
TOOLS = ["bin/gst-launch-1.0", "bin/gst-inspect-1.0", "libexec/gstreamer-1.0/gst-plugin-scanner"]


def run(*args):
    subprocess.run(args, check=True, capture_output=True)


def macho_deps(path):
    """Libraries a Mach-O file links to, excluding its own install name
    (otool -L lists a dylib's own id first)."""
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True, check=True).stdout
    own = subprocess.run(["otool", "-D", path], capture_output=True, text=True).stdout.splitlines()[1:]
    deps = [line.strip().split(" (")[0] for line in out.splitlines()[1:]]
    return [d for d in deps if d not in own]


def rpaths(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True, check=True).stdout.splitlines()
    found = []
    for i, line in enumerate(out):
        if "cmd LC_RPATH" in line:
            found.append(out[i + 2].split("path ")[1].split(" (offset")[0])
    return found


def resolve(ref, referrer):
    """Absolute path of a dependency, or None for system libraries."""
    if ref.startswith(("/usr/lib/", "/System/")):
        return None
    if ref.startswith(BREW):
        return os.path.realpath(ref)
    name = ref.split("/", 1)[1] if "/" in ref else ref
    here = os.path.dirname(os.path.realpath(referrer))
    candidates = []
    if ref.startswith("@rpath/"):
        for rp in rpaths(referrer):
            candidates.append(rp.replace("@loader_path", here).replace("@executable_path", here))
        candidates += [os.path.join(BREW, "lib"), here]
    elif ref.startswith(("@loader_path/", "@executable_path/")):
        candidates = [here]
    for d in candidates:
        p = os.path.normpath(os.path.join(d, name))
        if os.path.exists(p):
            return os.path.realpath(p)
    sys.exit(f"cannot resolve {ref} (from {referrer})")


def main():
    app = os.path.abspath(sys.argv[1])
    res = os.path.join(app, "Contents", "Resources")
    gst = os.path.join(res, "gst")
    lib = os.path.join(gst, "lib")
    plugdir = os.path.join(lib, "gstreamer-1.0")
    for d in (os.path.join(gst, "bin"), os.path.join(gst, "libexec"), plugdir):
        os.makedirs(d, exist_ok=True)

    # (source, destination, rpath from the destination's directory to lib/)
    work = []
    for t in TOOLS:
        dest_dir = "bin" if t.startswith("bin/") else "libexec"
        work.append((os.path.realpath(os.path.join(GST, t)),
                     os.path.join(gst, dest_dir, os.path.basename(t)), "@executable_path/../lib"))
    for p in PLUGINS:
        src = os.path.join(GST, "lib", "gstreamer-1.0", f"libgst{p}.dylib")
        if not os.path.exists(src):
            sys.exit(f"missing plugin {p}: {src}")
        work.append((os.path.realpath(src), os.path.join(plugdir, os.path.basename(src)), "@loader_path/.."))
    uxplay = os.path.join(app, "Contents", "Helpers", "receiver", "AirPlay Splitter")
    fix_only = [(uxplay, "@executable_path/../../Resources/gst/lib")] if os.path.exists(uxplay) else []

    copied = {}  # library basename -> source path

    def process(dest, rpath, source_for_resolving):
        os.chmod(dest, 0o755)
        changes = []
        for ref in macho_deps(dest)[0:]:
            src = resolve(ref, source_for_resolving)
            if src is None:
                continue
            name = os.path.basename(ref)
            if name not in copied:
                copied[name] = src
                target = os.path.join(lib, name)
                shutil.copy2(src, target)
                process(target, "@loader_path", src)
            changes += ["-change", ref, f"@rpath/{name}"]
        if dest.endswith(".dylib"):
            run("install_name_tool", "-id", f"@rpath/{os.path.basename(dest)}", dest)
        if changes:
            run("install_name_tool", *changes, dest)
        existing = rpaths(dest)
        for rp in existing:
            if rp.startswith(BREW) or rp.startswith("/opt/") or rp.startswith("/usr/local"):
                run("install_name_tool", "-delete_rpath", rp, dest)
        if rpath not in existing:
            run("install_name_tool", "-add_rpath", rpath, dest)

    for src, dest, rpath in work:
        shutil.copy2(src, dest)
        process(dest, rpath, src)
    for path, rpath in fix_only:
        process(path, rpath, path)

    # Nothing may still point into Homebrew.
    leftovers = []
    for root, _, files in os.walk(gst):
        for f in files:
            p = os.path.join(root, f)
            if any(r.startswith(BREW) for r in macho_deps(p)):
                leftovers.append(p)
    for path, _ in fix_only:
        if any(r.startswith(BREW) for r in macho_deps(path)):
            leftovers.append(path)
    if leftovers:
        sys.exit("still linked to Homebrew: " + ", ".join(leftovers))
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(gst) for f in fs)
    print(f"Bundled GStreamer: {len(PLUGINS)} plugins, {len(copied)} libraries, {size / 1e6:.0f} MB")


if __name__ == "__main__":
    main()
