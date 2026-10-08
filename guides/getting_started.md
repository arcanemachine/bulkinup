# Getting Started

Bulkinup validates attrs maps through your schemas' changeset functions, then writes a parent
and its nested associations across multiple tables in one call. This guide sets up the basics;
see [Nested Associations](nested_associations.html) for the multi-table part.

## Installation

Add the package to your list of dependencies in `mix.exs`, then run `mix deps.get`:

```elixir
def deps do
  [
    {:bulkinup, "~> 0.7.0"}
  ]
end
```

## A schema to work with

Here is a contrived migration and schema:

`priv/repo/migrations/0001_create_persons.exs`

```elixir
defmodule YourProject.Repo.Migrations.CreatePersons do
  use Ecto.Migration

  def change do
    create table(:persons) do
      add :name, :string
    end
  end
end
```

`lib/your_project/persons/person.ex`

```elixir
defmodule YourProject.Persons.Person do
  use Ecto.Schema
  import Ecto.Changeset

  schema "persons" do
    field :name, :string
  end

  def changeset(person \\ %__MODULE__{}, attrs) do
    person
    |> cast(attrs, [:id, :name])
    |> validate_required([:id, :name])
  end
end
```

The changeset function must be callable with a single argument (the attrs map) — a
`changeset/2` whose first argument defaults to an empty struct, as above, is the usual shape.

## Inserting and upserting

After running the migration (`mix ecto.migrate`), try it in an IEx shell (`iex -S mix`).
`Bulkinup.insert/4` is a pure bulk insert:

```text
iex> Bulkinup.insert(
...>   YourProject.Repo,
...>   YourProject.Persons.Person,
...>   [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]
...> )
{:ok, %{inserted: 2, skipped: 0}}
```

Running the same call again raises, because the rows already exist. `Bulkinup.upsert/4`
updates existing rows instead:

```text
iex> Bulkinup.upsert(
...>   YourProject.Repo,
...>   YourProject.Persons.Person,
...>   [%{id: 1, name: "Alicia"}, %{id: 2, name: "Bobby"}]
...> )
{:ok, %{upserted: 2, skipped: 0}}

iex> YourProject.Repo.all(YourProject.Persons.Person) |> Enum.map(& &1.name)
["Alicia", "Bobby"]
```

## Repo-scoped calls with `use Bulkinup`

Instead of passing the repo on every call, add `use Bulkinup` to your repo module. It injects
`bulk_insert/3` and `bulk_upsert/3`, and lets you declare app-wide defaults once:

```elixir
defmodule YourProject.Repo do
  use Ecto.Repo,
    otp_app: :your_project,
    adapter: Ecto.Adapters.Postgres

  use Bulkinup,
    upsert: [replace_all_except: [:inserted_at]]
end

YourProject.Repo.bulk_upsert(YourProject.Persons.Person, attrs_list)
```

See `Bulkinup.__using__/1` for the defaults and precedence rules.

## Invalid rows are skipped

Rows whose changesets are invalid are skipped rather than written. The `:skipped` count in the
return value shows how many:

```text
iex> Bulkinup.insert(
...>   YourProject.Repo,
...>   YourProject.Persons.Person,
...>   [%{id: 3, name: "Carol"}, %{id: 4}]
...> )
{:ok, %{inserted: 1, skipped: 1}}
```

Bulkinup does not log. To log or report the skipped rows, pass an `:on_skipped` handler, which
receives their changesets:

```elixir
require Logger

Bulkinup.insert(YourProject.Repo, YourProject.Persons.Person, attrs_list,
  on_skipped: fn %{changesets: changesets} ->
    Logger.warning("Skipped #{length(changesets)} invalid rows")
  end
)
```

See the Handlers section of `Bulkinup.upsert/4` for details, including the `:on_recovered`
handler.

A *database* error is different: it raises, and (by default) the surrounding transaction rolls
back every change from the call. To recover invalid rows instead of skipping them, see the
`:recover_changeset_errors` option in the [Recipes](recipes.html) guide.

## Where to next

- [Nested Associations](nested_associations.html) — writing a parent and its children across
  multiple tables in one call.
- [Recipes](recipes.html) — timestamps, streaming, conflict handling, dirty data.
- `Bulkinup.upsert/4` — the full options reference.
