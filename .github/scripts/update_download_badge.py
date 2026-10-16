#!/usr/bin/env python3
"""Render the public release download count without a third-party token pool."""

import argparse
import json
from pathlib import Path
import subprocess


def download_count(pages):
    return sum(
        asset["download_count"]
        for page in pages
        for release in page
        if not release.get("draft", False)
        for asset in release["assets"]
    )


def render_badge(count):
    if type(count) is not int or count < 0:
        raise ValueError("Download count must be a nonnegative integer")
    label_width = 69
    value_width = max(29, len(str(count)) * 7 + 10)
    width = label_width + value_width
    value_center = label_width + value_width / 2
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="20" role="img" aria-label="downloads: {count}">
  <title>downloads: {count}</title>
  <linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
  <clipPath id="r"><rect width="{width}" height="20" rx="3"/></clipPath>
  <g clip-path="url(#r)"><rect width="{label_width}" height="20" fill="#555"/><rect x="{label_width}" width="{value_width}" height="20" fill="#4c1"/><rect width="{width}" height="20" fill="url(#s)"/></g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
    <g fill="#010101" fill-opacity=".3" aria-hidden="true"><text x="34.5" y="15">downloads</text><text x="{value_center}" y="15">{count}</text></g>
    <text x="34.5" y="14">downloads</text><text x="{value_center}" y="14">{count}</text>
  </g>
</svg>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp",
         f"repos/{args.repository}/releases?per_page=100"],
        check=True, capture_output=True, text=True,
    )
    # Fetch and validate everything before replacing the last good badge.
    count = download_count(json.loads(result.stdout))
    svg = render_badge(count)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(svg, encoding="utf-8")
    print(f"Public release downloads: {count}")


if __name__ == "__main__":
    main()
