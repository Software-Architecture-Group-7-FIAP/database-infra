#!/usr/bin/env python3
"""Validate the selected S3 HeadObject fields before a state download."""

import argparse
import json
import sys
from pathlib import Path


class StateMetadataError(ValueError):
    """Raised when S3 metadata cannot safely identify a pinned object version."""


def validate_head_object_metadata(metadata):
    if not isinstance(metadata, dict):
        raise StateMetadataError("State object metadata is incomplete or unsupported.")

    version_id = metadata.get("VersionId")
    if (
        not isinstance(version_id, str)
        or not version_id
        or version_id != version_id.strip()
        or any(character.isspace() for character in version_id)
        or version_id in ("None", "null")
    ):
        raise StateMetadataError("State object metadata is incomplete or unsupported.")

    content_length = metadata.get("ContentLength")
    if (
        not isinstance(content_length, int)
        or isinstance(content_length, bool)
        or content_length < 0
    ):
        raise StateMetadataError("State object metadata is incomplete or unsupported.")

    return version_id, content_length


def read_head_object_metadata(path):
    try:
        metadata = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise StateMetadataError("State object metadata is incomplete or unsupported.") from error
    return validate_head_object_metadata(metadata)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metadata_file", type=Path)
    args = parser.parse_args()

    version_id, content_length = read_head_object_metadata(args.metadata_file)
    sys.stdout.write(f"{version_id} {content_length}\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except StateMetadataError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
