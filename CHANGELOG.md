# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions <= 0.5.x were released as
[`bulk_upsert`](https://hex.pm/packages/bulk_upsert).

## v0.8.0 - 2026-10-08

### Changed

- **Breaking:** Bulkinup no longer logs. The per-call `:warning` summary of skipped items, the
  per-item `:debug` details, and the `:debug` log for each recovered field are removed, along
  with their `:reason` log metadata. To keep logging skipped items, pass an `:on_skipped`
  handler that logs (see the Handlers section of `Bulkinup.upsert/4`)

### Added

- Options `:on_skipped` and `:on_recovered` take 1-arity handler functions, called once per
  chunk: `:on_skipped` receives the changesets of the skipped items, and `:on_recovered`
  receives the changesets whose errors were replaced by `:recover_changeset_errors` fallbacks
  (as they were before recovery)

## v0.7.0 - 2026-07-05

### Changed

- **Breaking:** The function-override options are renamed to idiomatic names:
  `:changeset_function_atom` is now `:changeset_function`, `:insert_all_function_atom` is now
  `:insert_all_function`, and `:insert_all_function_module` is now `:insert_all_module`. The
  old names raise an `ArgumentError` (at compile time when given to `use Bulkinup`)

## v0.6.0 - 2026-07-05

### Changed

- **Breaking:** The package is renamed from `bulk_upsert` to `bulkinup`, and
  `BulkUpsert.bulk_upsert/4` is now `Bulkinup.upsert/4` — same arguments, same options, same
  return shape. See the [migration guide](migrating_from_bulk_upsert.html)
- **Breaking:** The log metadata `:reason` atoms follow the rename:
  `:bulk_upsert_changeset_error` is now `:upsert_changeset_error`, and
  `:bulk_upsert_items_skipped` is now `:upsert_items_skipped` (with `:insert_changeset_error`
  and `:insert_items_skipped` as the `insert/4` counterparts)

### Added

- `Bulkinup.insert/4`: a pure bulk insert of nested schemas. No `on_conflict` or
  `conflict_target` defaults are applied at any level (including `many_to_many` join tables),
  so a duplicate raises. Returns `{:ok, %{inserted: n, skipped: n}}`. The upsert-only option
  `:replace_all_except` raises an `ArgumentError`
- `use Bulkinup`: injects repo-scoped `bulk_insert/3` and `bulk_upsert/3` into the calling
  repo module, with shared defaults declared once at `use` time. Flat keys apply to each verb
  they are valid for; `insert:`/`upsert:` namespaces hold per-verb defaults; per-call opts win.
  Option names are validated at compile time, and values are evaluated per call at runtime, so
  dynamic defaults work

## v0.5.0 - 2026-07-04

### Added

- `attrs_list` now accepts any `Enumerable`, including a lazy `Stream`: items are validated and
  upserted chunk-by-chunk, so memory stays bounded for arbitrarily large inputs. Plain lists
  behave as before, and skipped rows are still summarized in a single `:warning` log per call
- Option `:max_concurrency` to upsert chunks concurrently, each in its own transaction. Setting
  it trades the single-transaction guarantee for insert throughput — see the option's
  documentation for the consequences before using it

### Changed

- `bulk_upsert/4` now raises an `ArgumentError` when `:chunk_size` is not a positive integer
  (previously an invalid value failed deeper in the pipeline with an unclear error)

## v0.4.0 - 2026-07-04

### Changed

- **Breaking:** `bulk_upsert/4` now raises an `ArgumentError` on unknown option names, and on
  BulkUpsert options nested inside `:insert_all_opts` values (previously both were silently
  ignored). `:timeout` and `:placeholders` remain valid inside `:insert_all_opts`, since
  `insert_all/3` also accepts them
- Skipped rows are now summarized in a single `:warning` log per call (schema, counts, and up to
  50 skipped primary keys in the metadata), with per-row detail moved to the `:debug` level.
  Previously each skipped row logged its own `:warning`, which could flood the log during large
  imports of dirty data

## v0.3.0 - 2026-07-04

### Added

- Nested associations are now upserted recursively at any depth (previously only the parent's
  direct associations were handled, and a child carrying its own nested associations crashed)
- `:recover_changeset_errors` now applies recursively to nested association and embedded
  changesets, with fallbacks looked up by each changeset's schema (previously only the parent
  schema's changesets were recovered, and any nested error caused the row to be skipped)

### Changed

- **Breaking:** `bulk_upsert/4` now returns `{:ok, %{upserted: count, skipped: count}}` (counts
  of top-level attrs) instead of `:ok`, making silently skipped invalid rows visible to callers
- Require `ecto ~> 3.6` (the `:placeholders` option has required Ecto v3.6.0 all along; the
  previous `~> 3.0` requirement overstated compatibility)
- Skipped rows are now logged at the `:warning` level instead of `:debug`, since silently
  dropping invalid rows is data loss

### Fixed

- Wrap the entire bulk upsert in a single transaction. Previously each chunk of `:chunk_size`
  parents ran in its own transaction, so a failure in a later chunk left earlier chunks committed
- Placeholder fields can now be included in the changeset's `validate_required/2`. Each
  placeholder value is injected into the attrs (at every nesting level) before the changeset is
  built, so the field is cast and validated like any other field. Previously the value was absent
  during validation, so requiring a placeholder field silently skipped every row

## v0.2.0 - 2026-05-31

### Added

- Support for `has_one` associations
- Support for `many_to_many` associations (related records and join table rows)
- Option `:placeholders` to set fields from shared values via Ecto's `insert_all/3` placeholders

### Fixed

- Default `:insert_all_opts` to a map so string-keyed sources (e.g. join tables) work

## v0.1.5 - 2026-03-23

### Fixed

- Apply `chunk_size` option to `has_many` association upserts

## v0.1.4 - 2026-02-23

### Fixed

- Use separate variable for parent `insert_all_opts`

## v0.1.3 - 2026-02-20

### Fixed

- "Has many" assoc upserts now working

### Added

- Option `:chunk_size` (used to specify the maximum number of items to upsert in a single query)

## v0.1.2 - 2025-05-03

### Added

- Add changelog to HexDocs

## v0.1.1 - 2025-04-29

### Added

- Fix issues with docs

## v0.1.0 - 2025-04-28

### Added

- Initial release

