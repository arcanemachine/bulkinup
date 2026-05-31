# TODO

## Later candidates (surveyed from blink/ecto_unnest; undecided)

- `:returning` passthrough so callers get inserted rows/ids back (needs per-chunk result
  concatenation).
- Pluggable insert backends (COPY, `unnest`-based constant-text statements), formalizing the
  existing `:insert_all_module`/`:insert_all_function` escape hatch.
