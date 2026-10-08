# Migrating from bulk_upsert

Bulkinup is the continuation of the
[`bulk_upsert`](https://hex.pm/packages/bulk_upsert) package: versions <= 0.5.x were released
as `bulk_upsert`, and 0.6.0 is the first release as `bulkinup`. The upsert behavior is
unchanged — for existing callers the migration is a rename.

## 1. Swap the dependency

In `mix.exs`:

```elixir
# Before
{:bulk_upsert, "~> 0.5.0"}

# After
{:bulkinup, "~> 0.7.0"}
```

Then `mix deps.get`. (All `bulk_upsert` versions are retired on Hex — they still resolve and
compile, but every `deps.get` warns until you switch.)

## 2. Rename the call

`BulkUpsert.bulk_upsert/4` is now `Bulkinup.upsert/4` — same arguments, same return shape,
and the same options apart from the three renames below:

```elixir
# Before
BulkUpsert.bulk_upsert(YourProject.Repo, Person, attrs_list, opts)

# After
Bulkinup.upsert(YourProject.Repo, Person, attrs_list, opts)
```

`{:ok, %{upserted: n, skipped: n}}` is unchanged, so `with`/`case` matches on the return keep
working as-is.

## 3. Rename the function-override options

Three options were renamed in 0.7.0:

- `:changeset_function_atom` is now `:changeset_function`
- `:insert_all_function_atom` is now `:insert_all_function`
- `:insert_all_function_module` is now `:insert_all_module`

An old name raises an `ArgumentError` that lists the valid options — at compile time when
given to `use Bulkinup`, at call time otherwise.

## 4. (Optional) Replace a hand-rolled wrapper with `use Bulkinup`

If your repo module wraps the old call — the pattern the bulk_upsert README recommended —
consider `use Bulkinup`, which injects `bulk_insert/3` and `bulk_upsert/3` with app-wide
defaults declared once:

```elixir
defmodule YourProject.Repo do
  use Ecto.Repo,
    otp_app: :your_project,
    adapter: Ecto.Adapters.Postgres

  use Bulkinup,
    upsert: [replace_all_except: [:inserted_at]]
end
```

> #### Delete the wrapper first {: .warning}
>
> `use Bulkinup` injects plain `def`s, so a module that still defines its own `bulk_upsert/3`
> fails to compile. Delete the old wrapper function, then add `use Bulkinup`. Move any
> defaults the wrapper hard-coded into the `use` options (see `Bulkinup.__using__/1`).

Two small things to watch while moving the wrapper's defaults:

- `use Bulkinup` conventionally sits with the other `use` lines, above the module's `alias`
  lines — so fully qualify any module reference inside the `use` options (an alias defined
  further down is not in effect there).
- If the wrapper was the last user of an alias (or import), remove it too, or
  `mix compile --warnings-as-errors` will fail on the unused alias.

## Logging

Since 0.8.0, Bulkinup does not log, so the skipped-items `:warning` and the `:debug` details
(and their `:reason` metadata) are gone. To keep logging skipped items, pass an `:on_skipped`
handler (see the Handlers section of `Bulkinup.upsert/4`).

## What's new since 0.5.x

The rename repositions the library around nested bulk *writes*, with two sibling verbs:

- `Bulkinup.insert/4` — pure bulk insert: no conflict defaults anywhere, duplicates raise.
- `use Bulkinup` — repo-scoped calls with compile-time-validated, app-wide defaults.

See the [changelog](changelog.html) for details.
