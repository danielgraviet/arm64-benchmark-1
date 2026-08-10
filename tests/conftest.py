from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
VENDORED_REPO = ROOT / "workload" / "repos" / "sqlite-utils"


@pytest.fixture
def vendored_repo() -> Path:
    return VENDORED_REPO
