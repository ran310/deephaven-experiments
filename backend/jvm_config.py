"""JVM bootstrap for embedded Deephaven — avoids dh-default.vmoptions on newer JDKs."""

from __future__ import annotations

import os
import platform

from deephaven_server.start_jvm import _compiler_directives


def minimal_default_jvm_args() -> list[str]:
    """Deephaven defaults pull in vmoptions with flags removed in recent JDKs; this set keeps compiler directives only."""
    return [
        "-Xrs",
        "-XX:+UnlockDiagnosticVMOptions",
        f"-XX:CompilerDirectivesFile={_compiler_directives()}",
    ]


def user_jvm_args(heap: str | None = None) -> list[str]:
    mx = heap or os.environ.get("DEEPHAVEN_HEAP", "-Xmx2g")
    args = [
        mx,
        "-DAuthHandlers=io.deephaven.auth.AnonymousAuthenticationHandler",
    ]
    if platform.machine() == "arm64":
        args.append("-Dprocess.info.system-info.enabled=false")
    return args
