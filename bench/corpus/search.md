# Search

## How results are ranked

Semantic and keyword results are combined with reciprocal rank fusion. Each
list contributes a rank-based score, so a passage ranked highly by either
signal survives into the merged result even when the other signal misses it.

## Recency bias

Documents modified within the configured recency window receive a
multiplicative boost. The boost is applied after fusion, so it reorders results
rather than changing which ones are retrieved.

## Keyword-only and semantic-only modes

Either signal can be used alone. Keyword-only mode skips the embedding call
entirely and is therefore the only mode that works with the embedding service
unavailable.

## Why a query returns nothing

An empty result almost always means the file was never indexed or was indexed
before its last edit. Check the indexed file list and its index timestamp
before suspecting the ranking.
