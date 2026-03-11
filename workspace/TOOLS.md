# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## Web Search (SearXNG via mcporter)

When you need to search the web, **always use this command via your bash/shell tool**:

```bash
mcporter call searxng.searxng_web_search query="your search query"
```

To read full content from a URL found in results:

```bash
mcporter call searxng.web_url_read url="https://example.com"
```

This is your primary web search. No API keys needed. Do NOT use web_search (Brave) — it is not configured. Use mcporter instead.
