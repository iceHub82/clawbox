---
name: search
description: Search the web using the local SearXNG instance via mcporter MCP bridge. Use when the user asks to search the web, look something up, find information online, or needs current/recent data.
metadata:
  openclaw:
    emoji: "🔍"
---

# Web Search (SearXNG)

Search the web using the local SearXNG instance.

## Usage

Run searches via mcporter:

```bash
mcporter call searxng.searxng_web_search query="your search query"
```

Options:
- `time_range="day"` — limit to last 24h (also: `month`, `year`)
- `language="en"` — language code
- `pageno=2` — page number for more results

## Read URL content

To read the content of a URL from search results:

```bash
mcporter call searxng.web_url_read url="https://example.com"
```

## Examples

```bash
mcporter call searxng.searxng_web_search query="latest kubernetes release"
mcporter call searxng.searxng_web_search query="docker security CVE 2026" time_range="month"
mcporter call searxng.web_url_read url="https://www.docker.com/blog/"
```

## Notes

- No API keys required — SearXNG runs locally
- Results include title, description, URL, and relevance score
- Use `web_url_read` to fetch full content from any URL in the results
