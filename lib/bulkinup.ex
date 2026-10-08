defmodule Bulkinup do
  @moduledoc """
  Bulk inserts and upserts for nested Ecto schemas.

  Ecto's `c:Ecto.Repo.insert_all/3` writes one flat table at a time and skips changeset
  validation. Bulkinup fills that gap: it validates attrs maps through your schemas' changeset
  functions, then writes a parent **and its nested associations across multiple tables** in one
  call, wrapped in a single transaction by default.

  Two sibling verbs share the same engine, options, and semantics:

  - `upsert/4` — bulk upsert: existing rows are updated on conflict.
  - `insert/4` — pure bulk insert: writing a row that already exists raises.

  `use Bulkinup` (see `__using__/1`) injects repo-scoped `bulk_insert/3` and `bulk_upsert/3`
  into your repo module, with app-wide defaults declared once at `use` time.

  For a walkthrough, see the guides: [Getting Started](getting_started.html),
  [Nested Associations](nested_associations.html), [Recipes](recipes.html), and
  [Migrating from bulk_upsert](migrating_from_bulk_upsert.html).
  """

  @default_timeout 15_000

  @valid_options [
    :changeset_function,
    :chunk_size,
    :insert_all_function,
    :insert_all_module,
    :insert_all_opts,
    :max_concurrency,
    :on_recovered,
    :on_skipped,
    :placeholders,
    :recover_changeset_errors,
    :replace_all_except,
    :timeout
  ]

  # `:timeout` and `:placeholders` are also valid `insert_all/3` options, so they may appear
  # inside `:insert_all_opts` values as well
  @options_misplaced_inside_insert_all_opts @valid_options -- [:timeout, :placeholders]

  # Options that only make sense for an upsert; `insert/4` raises when given one
  @upsert_only_options [:replace_all_except]

  # The verbs, as they appear in the `use Bulkinup` per-verb namespaces
  @verbs [:insert, :upsert]

  @typedoc """
  Options accepted by `insert/4` and `upsert/4`. See `upsert/4`'s documentation for details.
  `:replace_all_except` is upsert-only: `insert/4` raises an `ArgumentError` when given it.

  Map keys typed `module() | Ecto.Schema.source()` accept a schema module or, for
  `many_to_many` join tables, the source as a string (e.g. `"persons_topics"`).
  """
  @type options :: [
          changeset_function: atom(),
          chunk_size: pos_integer(),
          insert_all_function: atom(),
          insert_all_module: module(),
          insert_all_opts: %{optional(module() | Ecto.Schema.source()) => Keyword.t()},
          max_concurrency: pos_integer(),
          on_recovered: (handler_input() -> any()),
          on_skipped: (handler_input() -> any()),
          placeholders: %{
            optional(module() | Ecto.Schema.source()) => %{optional(atom()) => term()}
          },
          recover_changeset_errors: %{optional(module()) => %{optional(atom()) => term()}},
          replace_all_except: [atom()],
          timeout: timeout()
        ]

  @typedoc """
  The map passed to the `:on_skipped` and `:on_recovered` handlers, once per chunk. See
  `upsert/4`'s documentation for details.
  """
  @type handler_input :: %{
          verb: :insert | :upsert,
          schema_module: module(),
          changesets: [Ecto.Changeset.t()]
        }

  @doc """
  Validate attrs maps (`attrs_list`) by passing them through an Ecto changeset, then upsert the
  valid items to the database that corresponds to a given Ecto `repo_module` (e.g.
  `YourProject.Repo`).

  `attrs_list` may be any `Enumerable` — a plain list, or a lazy `Stream` for large inputs (see
  the Streaming section below).

  Using a changeset serves two purposes:
    1. The changeset can be used to validate and transform the data.
    2. Using a changeset allows this function to perform bulk upserts with nested associations.

  For validation, each item in the `attrs_list` is converted to a changeset for a given
  `schema_module`. The changeset function is called with a single argument (the attrs map), so
  the schema module must expose a 1-arity changeset function — e.g. a `changeset/2` whose first
  argument defaults to an empty struct. By default, this function is called `:changeset`. (See
  the Options section below for more info.)

  ## Basic example

      iex> Bulkinup.upsert(
      ...>   YourProject.Repo,
      ...>   YourProject.Persons.Person,
      ...>   _attrs_list = [
      ...>     %{id: 1, name: "Alice", age: 25, phone_number: "555-1234"},
      ...>     %{id: 2, name: "Bob", age: 35, phone_number: "555-2345"},
      ...>   ]
      ...> )
      {:ok, %{upserted: 2, skipped: 0}}

  ## Return value

  Returns `{:ok, %{upserted: upserted_count, skipped: skipped_count}}`, where the counts refer to
  the top-level attrs: `:upserted` is the number of items sent to the database, and `:skipped` is
  the number of items dropped because their changesets were invalid. Bulkinup does not log; to
  inspect, log, or report the skipped items, pass an `:on_skipped` handler (see the Handlers
  section below). A database error raises; by default the entire upsert runs in a single
  transaction, so every change is rolled back (with `:max_concurrency`, only the failing chunk
  is — see below).

  ## Streaming

  `attrs_list` is consumed lazily, in chunks of `:chunk_size` items: a `Stream` is never fully
  materialized, so memory stays bounded for arbitrarily large inputs. Plain lists behave
  identically (same counts, same handler calls). Note that without
  `:max_concurrency`, the single transaction — and any locks it takes — stays open for the
  stream's full duration.

  ## Options

  Unknown option names raise an `ArgumentError`, as does passing a Bulkinup option (other than
  `:timeout` or `:placeholders`, which `insert_all/3` also accepts) inside an `:insert_all_opts`
  value.

  > #### Warning {: .warning}
  >
  > The `:changeset_function`, `:insert_all_function`, and `:insert_all_module`
  > options are invoked via `apply/3`. Never build these option values from untrusted (e.g.
  > user-supplied) input.

  - `:changeset_function` - The name of the changeset function to apply for the given
  `schema_module`. It is called with one argument: the attrs map. (Default: `:changeset`)

  - `:chunk_size` - The number of parent attrs items to insert into the database in a single
  query. Can be increased or decreased as needed to avoid exceeding the Postgres parameter limit
  for a single query. (Default: `1000`)

  - `:insert_all_function` - Instead of using your repo module's `:insert_all`
  function, you may pass a compatible equivalent that accepts the same arguments. (Default:
  `:insert_all`)
    - Example: `:insert_all_with_autogenerated_timestamps`

  - `:insert_all_module` - Instead of using the `:insert_all` function in the given
  `repo_module`, you may specify the name of a custom module to use instead. (Default:
  Inherited from the value specified in the `repo_module` function argument, e.g.
  `YourProject.Repo`)
    - Example: `YourProject.OtherRepo`

  - `:on_recovered` - A 1-arity function called with the changesets whose errors were replaced by
  `:recover_changeset_errors` fallbacks. See the Handlers section below. (Default: `nil`)

  - `:on_skipped` - A 1-arity function called with the changesets of the items that were skipped
  because of unrecoverable errors. See the Handlers section below. (Default: `nil`)

  - `:insert_all_opts` - Pass custom `opts` to the `insert_all/3` function. This option consists
  of a map whose key is the schema or source that may have items being upserted, and the value is
  the `YourProject.Repo.insert_all/3` opts that will be applied when items for that schema are
  being upserted. By default, a conflicting row has all of its values replaced except the primary
  key(s) (see the `:replace_all_except` option). (Default: `%{}`)
    - Example: `%{YourProject.Persons.Person => [on_conflict: {:nothing}]}`
    - A `many_to_many` join table is keyed by its source, e.g. `%{"persons_topics" => [...]}`.
    - `:conflict_target` defaults to the schema's primary key, so a schema without a primary key
    must supply its own `:conflict_target` here (otherwise the upsert fails at the database).

  - `:max_concurrency` - Upsert up to this many chunks of `:chunk_size` parents concurrently
  (via `Task.async_stream/3`), each chunk in its own transaction. By default, all chunks are
  upserted sequentially inside a single transaction. Setting this option trades the
  single-transaction guarantee for insert throughput: (Default: `nil`)
    - A failing chunk still raises, but chunks that already committed stay committed, so a
    failure partway through leaves the database with partial results.
    - `:timeout` applies to each chunk's transaction instead of the whole call.
    - Concurrent chunks that share `many_to_many` child records may upsert the same related (or
    join table) rows in different orders, which can deadlock in Postgres. Ensure concurrent
    input does not share child records across chunks, or be prepared to retry on deadlock.
    - In the test environment, the Ecto SQL sandbox requires shared mode (or explicit
    allowances) so the spawned tasks may use the test's database connection — e.g.
    `use MyApp.DataCase, async: false` with a Phoenix-style `setup_sandbox/1`.

  - `:placeholders` - Set fields from shared values that are sent to the database once instead of
  once per row, using the `:placeholders` feature of Ecto's `insert_all/3`. This option is a map
  whose key is the schema or source being upserted, and the value is a map of `field => value`.
  The fields do not need to appear in the attrs. (Default: `%{}`)
    - Example: `%{YourProject.Persons.Person => %{inserted_at: DateTime.utc_now()}}`
    - Each placeholder value is injected into the attrs before the changeset is built, so a
    placeholder field is cast and validated like any other field and may be included in the
    changeset's `validate_required/2`.
    - The shared value replaces any per-row value supplied for the field in the attrs.
    - Embedded schemas are stored inline on their parent row and are never upserted as their own
    source, so placeholder values keyed by an embedded schema module are ignored.

  - `:recover_changeset_errors` - If the given fields in a changeset have errors, then replace
  them with a custom fallback value. (Default: `%{}`)
    - Example: `%{YourProject.Persons.Person => %{phone_number: "INVALID"}}`
    - Applies recursively to nested association and embedded changesets, with fallbacks looked
    up by each changeset's schema (for embeds, the embedded schema module). A parent's
    association error is cleared once all of that association's child changesets have been
    recovered.
    - A changeset is only recovered if every one of its error fields has a fallback and every
    nested changeset is recoverable by the same rule; otherwise the row is skipped.
    - A fallback value is applied without re-running the changeset function, so it must be valid
    for the schema.
    - Errors on the association and embed fields themselves (e.g. an association whose attrs
    could not be cast at all) are never recoverable.

  - `:replace_all_except` - If a row already exists, then all fields will be replaced except the
  primary key, and any fields specified here. (Default: `[]`)
    - Example: `[:field, :other_field]`

  - `:timeout` - The maximum timeout for the transaction that wraps the entire bulk upsert (all
  chunks), also applied to each `insert_all/3` query. With `:max_concurrency`, the timeout
  applies to each chunk's transaction instead. (Default: `#{@default_timeout}`)
    - Example: `60_000`

  ## Handlers

  Bulkinup does not log. Instead, the `:on_skipped` and `:on_recovered` handlers receive the
  affected changesets, so the caller decides what to do with them (log them at a chosen level,
  report them to an error tracker, collect them, etc.). Each handler is called once per chunk
  that has affected items, with a `t:handler_input/0` map:

      %{verb: :upsert, schema_module: YourProject.Persons.Person, changesets: changesets}

  - `:on_skipped` receives the top-level changesets of the skipped items. Each changeset's
  `errors` (and its nested changesets' errors) explain why the item was skipped.
  - `:on_recovered` receives each changeset (top-level or nested) whose errors were replaced by
  fallback values, as it was before the fallbacks were applied. Each changeset's `errors` list
  the fields that were replaced, and why. Only changesets of items that were written are
  included: a recovered changeset inside a skipped item is not reported.

  A handler runs inside the chunk's transaction, after the chunk's valid items are written:

  - A slow handler holds the transaction (and its locks) open.
  - A handler that raises rolls back the transaction, and the exception propagates to the caller.
  - Without `:max_concurrency`, a later chunk that fails rolls back the items of chunks that were
  already reported to a handler.
  - With `:max_concurrency`, a handler runs in a task process, so it does not inherit the
  caller's process dictionary or `Logger` metadata.

  For example, to log a summary of each chunk's skipped items:

      require Logger

      Bulkinup.upsert(YourProject.Repo, YourProject.Persons.Person, attrs_list,
        on_skipped: fn %{schema_module: schema_module, changesets: changesets} ->
          Logger.warning(
            "Skipped \#{length(changesets)} \#{inspect(schema_module)} items with invalid " <>
              "changesets: \#{inspect(Enum.map(changesets, & &1.errors))}"
          )
        end
      )

  To apply a handler to every call, set it in the `use Bulkinup` defaults (see `__using__/1`),
  e.g. `use Bulkinup, on_skipped: &YourProject.BulkinupHandlers.log_skipped/1`.

  ## Examples

  Upsert a list of Person attrs using the changeset function
  `YourProject.Persons.Person.upsert_changeset/2` to validate the attrs:

      iex> attrs_list = [%{id: 1, name: "Alice", ...}]

      iex> Bulkinup.upsert(
      ...>   YourProject.Repo,
      ...>   YourProject.Persons.Person,
      ...>   attrs_list,
      ...>   changeset_function: :upsert_changeset
      ...> )
      {:ok, %{upserted: 1, skipped: 0}}

  Upsert a list of attrs, overwriting only the `:name` field if there is a conflict. Schemas that
  are not given custom `:insert_all_opts` keep the default conflict behavior (replace all fields
  except the primary key):

      iex> insert_all_opts = %{
      ...>   YourProject.Persons.Person => [on_conflict: {:replace, [:name]}]
      ...> }

      iex> Bulkinup.upsert(
      ...>   YourProject.Repo,
      ...>   YourProject.Persons.Person,
      ...>   _attrs_list = [%{id: 1, name: "Alicia"}],
      ...>   insert_all_opts: insert_all_opts
      ...> )
      {:ok, %{upserted: 1, skipped: 0}}

  ## Associations

  Nested associations are upserted in the same call as the parent, recursively: a child's own
  nested associations (at any depth) are upserted the same way as the parent's.

  This is an upsert-only operation: rows absent from the attrs are left untouched at every level.
  Unlike `Ecto.Changeset.cast_assoc/3`'s `:on_replace` behavior, absent children are never
  deleted or nilified.

  - `has_many` and `has_one`: the associated records are upserted into their own table. Each child
  must include its foreign key in its attrs, since it is upserted directly via `insert_all/3`.

  - `many_to_many`: the associated records are upserted into their own table, and the join table
  rows linking each parent to its associations are upserted as well. Duplicate records and links
  are removed automatically.

  - `embeds_one` and `embeds_many`: embedded data has no table of its own, so it is stored inline
  on the parent row as part of the parent upsert.

  ## Known limitations

  - Nested `belongs_to` associations are not upserted. To associate with a `belongs_to` parent,
  include its foreign key field in the attrs (e.g. `category_id`). This applies at every level of
  nesting.
  """
  @spec upsert(module(), module(), Enumerable.t(map()), options()) ::
          {:ok, %{upserted: non_neg_integer(), skipped: non_neg_integer()}}
  def upsert(repo_module, schema_module, attrs_list, opts \\ []) do
    bulk_write(:upsert, repo_module, schema_module, attrs_list, opts)
  end

  @doc """
  Like `upsert/4`, but a pure bulk insert: rows are only ever created, never updated.

  No `on_conflict` or `conflict_target` defaults are applied at any level — the parent schema,
  nested associations, and `many_to_many` join tables all use Ecto's default conflict behavior,
  so inserting a row (or join table link) that already exists raises (a `Postgrex.Error` unique
  violation on Postgres). By default the entire insert runs in a single transaction, so every
  change is rolled back when a duplicate raises.

  To tolerate children or join rows shared with data that is already in the database (e.g.
  `many_to_many` records that several parents reference), override the conflict behavior for
  just those sources via `:insert_all_opts`:

      iex> Bulkinup.insert(
      ...>   YourProject.Repo,
      ...>   YourProject.Blog.Post,
      ...>   attrs_list,
      ...>   insert_all_opts: %{
      ...>     YourProject.Blog.Tag => [on_conflict: :nothing],
      ...>     "posts_tags" => [on_conflict: :nothing]
      ...>   }
      ...> )
      {:ok, %{inserted: 2, skipped: 0}}

  Returns `{:ok, %{inserted: inserted_count, skipped: skipped_count}}`, with the same meaning
  as `upsert/4`'s counts.

  Everything else — changeset validation, `:recover_changeset_errors`, `:placeholders`,
  chunking, streaming input, `:max_concurrency`, `:timeout`, and the `:on_skipped` and
  `:on_recovered` handlers — behaves exactly as documented for `upsert/4`. The upsert-only
  option `:replace_all_except` raises an `ArgumentError`.
  """
  @spec insert(module(), module(), Enumerable.t(map()), options()) ::
          {:ok, %{inserted: non_neg_integer(), skipped: non_neg_integer()}}
  def insert(repo_module, schema_module, attrs_list, opts \\ []) do
    bulk_write(:insert, repo_module, schema_module, attrs_list, opts)
  end

  @doc """
  Injects `bulk_insert/3` and `bulk_upsert/3` into the calling repo module — `insert/4` and
  `upsert/4` scoped to that repo, with shared defaults declared once at `use` time:

      defmodule YourProject.Repo do
        use Ecto.Repo, otp_app: :your_project, adapter: Ecto.Adapters.Postgres

        use Bulkinup,
          timeout: fetch_timeout!(),
          insert: [chunk_size: 500],
          upsert: [replace_all_except: [:inserted_at]]
      end

      YourProject.Repo.bulk_upsert(Person, attrs_list)
      {:ok, %{upserted: 2, skipped: 0}}

  ## Defaults and precedence

  - A flat key (e.g. `timeout:` above) is a shared default, applied to each verb it is valid
    for. The upsert-only `:replace_all_except` is applied to `bulk_upsert/3` only — though
    passing it per-call to `bulk_insert/3` still raises, as it does for `insert/4`.
  - The `insert:` and `upsert:` keys hold per-verb defaults.
  - Precedence: per-call opts override the verb namespace, which overrides flat keys.

  Option names are validated at compile time: a typo, or a key that is valid for no verb it
  would apply to, is a compile error. Option *values* are injected unevaluated and evaluated
  per call at runtime, so dynamic defaults (like `fetch_timeout!()` above, resolved in the
  repo module) work.
  """
  defmacro __using__(use_opts) do
    {flat_opts, verb_opts} = validate_use_opts!(use_opts)

    insert_defaults = build_verb_defaults(:insert, flat_opts, verb_opts)
    upsert_defaults = build_verb_defaults(:upsert, flat_opts, verb_opts)

    quote do
      @doc "`Bulkinup.insert/4` scoped to this repo, with the `use Bulkinup` defaults applied."
      def bulk_insert(schema_module, attrs_list, opts \\ []) do
        defaults = unquote(insert_defaults)
        Bulkinup.insert(__MODULE__, schema_module, attrs_list, Keyword.merge(defaults, opts))
      end

      @doc "`Bulkinup.upsert/4` scoped to this repo, with the `use Bulkinup` defaults applied."
      def bulk_upsert(schema_module, attrs_list, opts \\ []) do
        defaults = unquote(upsert_defaults)
        Bulkinup.upsert(__MODULE__, schema_module, attrs_list, Keyword.merge(defaults, opts))
      end
    end
  end

  # Validate the `use Bulkinup` option names at compile time. Values are AST and are not
  # evaluated here — they are injected into the generated functions and evaluated per call.
  defp validate_use_opts!(use_opts) do
    if not Keyword.keyword?(use_opts) do
      raise ArgumentError, """
      `use Bulkinup` expects a literal keyword list of options, \
      got: #{Macro.to_string(use_opts)}\
      """
    end

    {verb_opts, flat_opts} = Keyword.split(use_opts, @verbs)

    unknown_options = flat_opts |> Keyword.keys() |> Enum.uniq() |> Kernel.--(@valid_options)

    if unknown_options != [] do
      raise ArgumentError, """
      unknown option(s) #{inspect(unknown_options)} given to `use Bulkinup`.

      Valid options: #{inspect(@valid_options)}, plus the #{inspect(@verbs)} per-verb \
      namespaces\
      """
    end

    Enum.each(verb_opts, fn {verb, verb_defaults} ->
      if not Keyword.keyword?(verb_defaults) do
        raise ArgumentError, """
        the `use Bulkinup` option `#{inspect(verb)}:` expects a literal keyword list of \
        defaults for that verb, got: #{Macro.to_string(verb_defaults)}\
        """
      end

      valid_verb_options = valid_options_for_verb(verb)

      invalid_options =
        verb_defaults |> Keyword.keys() |> Enum.uniq() |> Kernel.--(valid_verb_options)

      if invalid_options != [] do
        raise ArgumentError, """
        invalid option(s) #{inspect(invalid_options)} in the `#{inspect(verb)}:` namespace \
        given to `use Bulkinup`.

        Valid options for `#{inspect(verb)}:`: #{inspect(valid_verb_options)}\
        """
      end
    end)

    {flat_opts, verb_opts}
  end

  defp valid_options_for_verb(:insert), do: @valid_options -- @upsert_only_options
  defp valid_options_for_verb(:upsert), do: @valid_options

  # Merge a verb's defaults at compile time (the values stay unevaluated AST): flat keys the
  # verb accepts, overridden by the verb's namespace
  defp build_verb_defaults(verb, flat_opts, verb_opts) do
    flat_opts
    |> Keyword.take(valid_options_for_verb(verb))
    |> Keyword.merge(Keyword.get(verb_opts, verb, []))
  end

  # The shared write engine: validate, chunk, write, and summarize. Verb-specific behavior
  # (conflict defaults and the verb's count key) dispatches on `config.verb`.
  defp bulk_write(verb, repo_module, schema_module, attrs_list, opts) do
    validate_opts!(verb, opts)

    # Parse all options once; `config` is threaded through every helper below
    config = %{
      verb: verb,
      changeset_function: Keyword.get(opts, :changeset_function, :changeset),
      chunk_size: Keyword.get(opts, :chunk_size, 1000),
      max_concurrency: Keyword.get(opts, :max_concurrency),
      on_recovered: Keyword.get(opts, :on_recovered),
      on_skipped: Keyword.get(opts, :on_skipped),
      recover_changeset_errors: Keyword.get(opts, :recover_changeset_errors, %{}),
      insert_all_module: Keyword.get(opts, :insert_all_module, repo_module),
      insert_all_function: Keyword.get(opts, :insert_all_function, :insert_all),
      insert_all_opts: Keyword.get(opts, :insert_all_opts, %{}),
      replace_all_except: Keyword.get(opts, :replace_all_except, []),
      placeholders: Keyword.get(opts, :placeholders, %{}),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }

    attrs_list =
      if config.placeholders == %{} do
        attrs_list
      else
        # Inject each placeholder value into the attrs before the changeset is built, so a
        # placeholder field is cast and validated like any other field (and may be included in
        # `validate_required/2`). The value is swapped for a `{:placeholder, field}` tuple after
        # validation, in `insert_all_entries/4`
        Stream.map(attrs_list, &inject_placeholder_values(&1, schema_module, config.placeholders))
      end

    # Build changesets lazily and chunk large payloads to stay within Postgres bulk limits.
    # Laziness lets any `Enumerable` (including a `Stream`) be validated and written
    # chunk-by-chunk without materializing the whole input
    changeset_chunks =
      attrs_list
      # Convert to changesets so the data can be validated before writing
      |> Stream.map(fn attrs -> apply(schema_module, config.changeset_function, [attrs]) end)
      |> Stream.chunk_every(config.chunk_size)

    totals =
      changeset_chunks
      |> write_chunks(repo_module, schema_module, config)
      |> Enum.reduce(%{written: 0, skipped: 0}, fn chunk_result, totals ->
        %{
          written: totals.written + chunk_result.written,
          skipped: totals.skipped + chunk_result.skipped
        }
      end)

    {:ok, %{count_key(verb) => totals.written, skipped: totals.skipped}}
  end

  # The key the verb's written count is returned under
  defp count_key(:insert), do: :inserted
  defp count_key(:upsert), do: :upserted

  # Write every chunk sequentially, wrapped in a single transaction so that any failure rolls
  # back all changes made to every chunk of parents and all of their associations
  defp write_chunks(
         changeset_chunks,
         repo_module,
         schema_module,
         %{max_concurrency: nil} = config
       ) do
    {:ok, chunk_results} =
      repo_module.transaction(
        fn -> Enum.map(changeset_chunks, &write_chunk(schema_module, &1, config)) end,
        timeout: config.timeout
      )

    chunk_results
  end

  # Write chunks concurrently, each in its own transaction. A failing chunk raises in the
  # caller, but chunks that already committed stay committed (see the `:max_concurrency` docs)
  defp write_chunks(changeset_chunks, repo_module, schema_module, config) do
    changeset_chunks
    |> Task.async_stream(
      fn changesets ->
        # An exception is returned instead of raised, then reraised in the caller below, so a
        # failing chunk propagates the original error (e.g. a `Postgrex.Error`) just like the
        # sequential mode, rather than exiting the caller
        try do
          {:ok, chunk_result} =
            repo_module.transaction(
              fn -> write_chunk(schema_module, changesets, config) end,
              timeout: config.timeout
            )

          {:ok, chunk_result}
        rescue
          exception -> {:raised, exception, __STACKTRACE__}
        end
      end,
      max_concurrency: config.max_concurrency,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, {:ok, chunk_result}} -> chunk_result
      {:ok, {:raised, exception, stacktrace}} -> reraise(exception, stacktrace)
    end)
  end

  # Validate, recover, and write one chunk of parent changesets, report the chunk's recovered and
  # skipped changesets to their handlers, and return the chunk's counts
  defp write_chunk(schema_module, changesets, config) do
    {valid_results, invalid_results} =
      changesets
      |> Enum.map(&recover_changeset(&1, config.recover_changeset_errors))
      |> Enum.split_with(fn {changeset, _recovered_changesets} -> changeset.valid? end)

    valid_changesets = Enum.map(valid_results, &elem(&1, 0))
    invalid_changesets = Enum.map(invalid_results, &elem(&1, 0))

    if valid_changesets != [], do: do_bulk_write(schema_module, valid_changesets, config)

    # Recoveries inside a skipped item are not reported, since the item was not written
    recovered_changesets = Enum.flat_map(valid_results, &elem(&1, 1))

    call_handler(config.on_recovered, recovered_changesets, schema_module, config.verb)
    call_handler(config.on_skipped, invalid_changesets, schema_module, config.verb)

    %{written: length(valid_changesets), skipped: length(invalid_changesets)}
  end

  defp call_handler(handler, changesets, schema_module, verb) do
    if handler != nil and changesets != [] do
      handler.(%{verb: verb, schema_module: schema_module, changesets: changesets})
    end
  end

  # Raise on unknown option names, on upsert-only options given to `insert/4`, and on
  # Bulkinup-level options nested inside `:insert_all_opts` values. The keys of each
  # `:insert_all_opts` value are otherwise not checked, since the set of valid `insert_all/3`
  # options belongs to Ecto.
  defp validate_opts!(verb, opts) do
    unknown_options = opts |> Keyword.keys() |> Enum.uniq() |> Kernel.--(@valid_options)

    if unknown_options != [] do
      raise ArgumentError, """
      unknown option(s) #{inspect(unknown_options)}.

      Valid options: #{inspect(@valid_options)}\
      """
    end

    upsert_only_options =
      if verb == :insert,
        do: opts |> Keyword.keys() |> Enum.uniq() |> Enum.filter(&(&1 in @upsert_only_options)),
        else: []

    if upsert_only_options != [] do
      raise ArgumentError, """
      the option(s) #{inspect(upsert_only_options)} only apply to an upsert, and are not \
      supported by `insert/4`. Use `upsert/4` instead, or drop the option(s).\
      """
    end

    chunk_size = Keyword.get(opts, :chunk_size, 1000)

    if not (is_integer(chunk_size) and chunk_size > 0) do
      raise ArgumentError, """
      the `:chunk_size` option must be a positive integer, got: #{inspect(chunk_size)}\
      """
    end

    max_concurrency = Keyword.get(opts, :max_concurrency)

    if not (is_nil(max_concurrency) or (is_integer(max_concurrency) and max_concurrency > 0)) do
      raise ArgumentError, """
      the `:max_concurrency` option must be a positive integer, got: #{inspect(max_concurrency)}\
      """
    end

    Enum.each([:on_recovered, :on_skipped], fn handler_option ->
      handler = Keyword.get(opts, handler_option)

      if not (is_nil(handler) or is_function(handler, 1)) do
        raise ArgumentError, """
        the `#{inspect(handler_option)}` option must be a 1-arity function, \
        got: #{inspect(handler)}\
        """
      end
    end)

    insert_all_opts = Keyword.get(opts, :insert_all_opts, %{})

    if not is_map(insert_all_opts) do
      raise ArgumentError, """
      the `:insert_all_opts` option must be a map of `schema_or_source => insert_all_opts`, \
      got: #{inspect(insert_all_opts)}\
      """
    end

    Enum.each(insert_all_opts, fn {schema_or_source, schema_insert_all_opts} ->
      misplaced_options =
        if Keyword.keyword?(schema_insert_all_opts),
          do:
            schema_insert_all_opts
            |> Keyword.keys()
            |> Enum.uniq()
            |> Enum.filter(&(&1 in @options_misplaced_inside_insert_all_opts)),
          else: []

      if misplaced_options != [] do
        raise ArgumentError, """
        the option(s) #{inspect(misplaced_options)} given for #{inspect(schema_or_source)} are \
        Bulkinup options, and have no effect inside `:insert_all_opts`. Pass them at the top \
        level of `opts` instead.\
        """
      end
    end)
  end

  # Inject the placeholder values configured for a schema into an attrs map, recursing into the
  # attrs of every association that will be upserted. The shared placeholder value replaces any
  # per-row value for the field.
  defp inject_placeholder_values(attrs, schema_module, placeholders) do
    attrs =
      placeholders
      |> Map.get(schema_module, %{})
      |> Enum.reduce(attrs, fn {field, value}, acc -> put_placeholder_attr(acc, field, value) end)

    # Recurse into the associations that are upserted (`has_many`, `has_one`, `many_to_many`)
    (get_schema_associations(schema_module, :has) ++
       get_schema_associations(schema_module, :many_to_many))
    |> Enum.reduce(attrs, fn association, acc ->
      related_schema_module = schema_module.__schema__(:association, association).related

      update_association_attrs(
        acc,
        association,
        &inject_placeholder_values(&1, related_schema_module, placeholders)
      )
    end)
  end

  # Attrs maps may use string or atom keys, and Ecto's `cast/4` raises on maps that mix both, so
  # the injected key must match the keys already present.
  defp put_placeholder_attr(attrs, field, value) do
    if Enum.any?(Map.keys(attrs), &is_binary/1),
      do: Map.put(attrs, Atom.to_string(field), value),
      else: Map.put(attrs, field, value)
  end

  # Apply `fun` to each attrs map under an association key, if the association is present.
  # Values that are not attrs maps (or lists of them) are left untouched, so the changeset cast
  # reports them as errors in the usual way.
  defp update_association_attrs(attrs, association, fun) do
    key =
      cond do
        Map.has_key?(attrs, association) -> association
        Map.has_key?(attrs, Atom.to_string(association)) -> Atom.to_string(association)
        true -> nil
      end

    if is_nil(key) do
      attrs
    else
      Map.update!(attrs, key, fn
        children when is_list(children) ->
          Enum.map(children, fn
            child when is_map(child) -> fun.(child)
            not_a_map -> not_a_map
          end)

        child when is_map(child) ->
          fun.(child)

        not_attrs ->
          not_attrs
      end)
    end
  end

  defp attrs_from_changeset(changeset) do
    struct = Ecto.Changeset.apply_action!(changeset, :bulk_write)

    struct
    |> Map.from_struct()
    |> Map.reject(fn {k, _v} -> k not in Map.keys(changeset.changes) end)
  end

  # Upsert a list of entries into a schema or source, applying any configured placeholders and
  # chunking large payloads to stay within Postgres bulk limits.
  defp insert_all_entries(entries, schema_or_source, insert_all_opts, context) do
    placeholder_values = context.placeholders[schema_or_source] || %{}

    # Placeholder fields are set here, after changeset validation, because a `{:placeholder, key}`
    # tuple cannot pass through a changeset. Each placeholder value is sent to Postgres once.
    {entries, insert_all_opts} =
      if placeholder_values == %{} do
        {entries, insert_all_opts}
      else
        placeholder_attrs =
          Map.new(placeholder_values, fn {field, _value} -> {field, {:placeholder, field}} end)

        {
          Enum.map(entries, &Map.merge(&1, placeholder_attrs)),
          Keyword.put(insert_all_opts, :placeholders, placeholder_values)
        }
      end

    entries
    |> Enum.chunk_every(context.chunk_size)
    |> Enum.each(fn entries_chunk ->
      apply(context.insert_all_module, context.insert_all_function, [
        schema_or_source,
        entries_chunk,
        insert_all_opts
      ])
    end)
  end

  # Write one schema's rows and recurse into its associations, applying the verb's default
  # conflict behavior (see `default_schema_insert_all_opts/3`) at every level
  defp do_bulk_write(schema_module, changesets, config) do
    %{insert_all_opts: insert_all_opts} = config

    # Perform the bulk write for all parent attrs
    attrs_list =
      changesets
      # Drop all assoc data from the changeset (assocs are handled separately in a later step)
      |> Enum.map(&drop_association_changes(&1, schema_module))
      |> Enum.map(&attrs_from_changeset/1)

    # Build `insert_all` opts for the parent schema
    parent_insert_all_opts =
      Keyword.merge(
        default_schema_insert_all_opts(config.verb, schema_module, config),
        insert_all_opts[schema_module] || []
      )

    insert_all_entries(attrs_list, schema_module, parent_insert_all_opts, config)

    # Perform the bulk write for all `has_many` and `has_one` associations
    for association <- get_schema_associations(schema_module, :has) do
      association_schema_module =
        schema_module.__changeset__()[association] |> elem(1) |> Map.fetch!(:related)

      association_changesets =
        changesets
        |> Enum.map(& &1.changes)
        |> Enum.map(&Map.get(&1, association))
        # `has_many` changes are a list of changesets; `has_one` changes are a single
        # changeset; an absent association is `nil`. `List.wrap/1` normalizes each into a
        # (possibly empty) list, which `flat_map` concatenates.
        |> Enum.flat_map(&List.wrap/1)

      # Recurse so each child's own nested associations are written as well
      do_bulk_write(association_schema_module, association_changesets, config)
    end

    # Perform the bulk write for all `many_to_many` associations
    for association <- get_schema_associations(schema_module, :many_to_many) do
      %Ecto.Association.ManyToMany{
        related: related_schema_module,
        join_through: join_through,
        join_keys: [{owner_join_key, owner_key}, {related_join_key, related_key}]
      } = schema_module.__changeset__()[association] |> elem(1)

      # Pair each parent's primary key with each of its related changesets, so the related
      # records and the join rows can both be derived from the same data.
      parent_related_pairs =
        Enum.flat_map(changesets, fn parent_changeset ->
          parent_changeset.changes
          |> Map.get(association)
          |> List.wrap()
          |> Enum.map(fn related_changeset -> {parent_changeset, related_changeset} end)
        end)

      # Write the related records into their own table. The same record may be referenced by
      # multiple parents, so duplicates are removed to avoid conflicting twice in one query.
      related_changesets =
        parent_related_pairs
        |> Enum.map(fn {_parent_changeset, related_changeset} -> related_changeset end)
        |> Enum.uniq_by(fn related_changeset ->
          related_schema_module.__schema__(:primary_key)
          |> Enum.map(&Ecto.Changeset.get_field(related_changeset, &1))
        end)

      # Recurse so each related record's own nested associations are written as well
      do_bulk_write(related_schema_module, related_changesets, config)

      # Write the join table rows that link each parent to its related records. The same link
      # may be listed more than once, so duplicate rows are removed for the same reason.
      join_attrs_list =
        parent_related_pairs
        |> Enum.map(fn {parent_changeset, related_changeset} ->
          %{
            owner_join_key => Ecto.Changeset.fetch_field!(parent_changeset, owner_key),
            related_join_key => Ecto.Changeset.fetch_field!(related_changeset, related_key)
          }
        end)
        |> Enum.uniq()

      join_insert_all_opts =
        Keyword.merge(
          default_join_insert_all_opts(config.verb, [owner_join_key, related_join_key], config),
          insert_all_opts[join_through] || []
        )

      insert_all_entries(
        join_attrs_list,
        join_through,
        join_insert_all_opts,
        config
      )
    end
  end

  # Default `insert_all` opts for a schema's own rows, per verb. An insert sets no conflict
  # options at all, so a duplicate row raises (Ecto's default behavior); an upsert conflicts on
  # the primary key and replaces every other field (minus `:replace_all_except`).
  defp default_schema_insert_all_opts(:insert, _schema_module, config) do
    [timeout: config.timeout]
  end

  defp default_schema_insert_all_opts(:upsert, schema_module, config) do
    [
      conflict_target: schema_module.__schema__(:primary_key),
      on_conflict:
        {:replace_all_except, schema_module.__schema__(:primary_key) ++ config.replace_all_except},
      timeout: config.timeout
    ]
  end

  # Default `insert_all` opts for a `many_to_many` join table's rows, per verb. An insert sets
  # no conflict options here either, so a duplicate link raises just like a duplicate row; an
  # upsert ignores links that already exist.
  defp default_join_insert_all_opts(:insert, _join_keys, config) do
    [timeout: config.timeout]
  end

  defp default_join_insert_all_opts(:upsert, join_keys, config) do
    [on_conflict: :nothing, conflict_target: join_keys, timeout: config.timeout]
  end

  # Association changes cannot pass through `insert_all/3`, so they are dropped from the row's
  # own upsert. (They are upserted separately, by recursing into each association's changesets.)
  defp drop_association_changes(%Ecto.Changeset{} = changeset, schema_module) do
    Map.update!(changeset, :changes, &Map.drop(&1, schema_module.__schema__(:associations)))
  end

  # Get all `has_many` and `has_one` associations for a given schema.
  defp get_schema_associations(schema_module, :has) do
    schema_module.__changeset__()
    |> Enum.filter(fn {_k, v} ->
      match?({:assoc, %Ecto.Association.Has{}}, v)
    end)
    |> Keyword.keys()
  end

  # Get all `many_to_many` associations for a given schema.
  defp get_schema_associations(schema_module, :many_to_many) do
    schema_module.__changeset__()
    |> Enum.filter(fn {_k, v} ->
      match?({:assoc, %Ecto.Association.ManyToMany{}}, v)
    end)
    |> Keyword.keys()
  end

  # Recover a single changeset, recursing into its nested association changesets first
  # (bottom-up). An association's error on the parent is cleared once all of that association's
  # child changesets are valid. The changeset itself is then recovered only if every remaining
  # error field has a fallback configured for the changeset's schema.
  #
  # Returns `{changeset, recovered_changesets}`, where `recovered_changesets` holds every
  # changeset (this one or a nested one) whose field errors were replaced by fallbacks, as it
  # was before the fallbacks were applied.
  defp recover_changeset(%Ecto.Changeset{valid?: true} = changeset, _recover_changeset_errors) do
    {changeset, []}
  end

  defp recover_changeset(changeset, recover_changeset_errors)
       when recover_changeset_errors == %{} do
    {changeset, []}
  end

  defp recover_changeset(changeset, recover_changeset_errors) do
    schema_module = changeset.data.__struct__

    # Recover the nested association and embed changesets before the changeset's own errors,
    # since a nested error can only be cleared once all of its child changesets are valid
    {changeset, nested_recovered_changesets} =
      (schema_module.__schema__(:associations) ++ schema_module.__schema__(:embeds))
      |> Enum.reduce({changeset, []}, fn association, {acc_changeset, acc_recovered} ->
        {acc_changeset, recovered} =
          recover_nested_changesets(acc_changeset, association, recover_changeset_errors)

        {acc_changeset, acc_recovered ++ recovered}
      end)

    fallbacks = Map.get(recover_changeset_errors, schema_module, %{})
    error_fields = changeset.errors |> Keyword.keys() |> Enum.uniq()

    # An error on an association or embed field itself (e.g. attrs that could not be cast) is
    # never recoverable: a fallback value would replace the field's changesets in the changes
    # with a bare value
    nested_fields = schema_module.__schema__(:associations) ++ schema_module.__schema__(:embeds)
    recoverable_field? = &(Map.has_key?(fallbacks, &1) and &1 not in nested_fields)

    cond do
      # An invalid child does not always leave an error entry on its parent (`cast_assoc/3` may
      # only set `valid?: false`), so the children's own validity is checked directly. A
      # changeset with an unrecovered child cannot be recovered
      not nested_changesets_valid?(changeset, schema_module) ->
        {changeset, nested_recovered_changesets}

      error_fields == [] ->
        # Every error was an association error, and all child changesets have been recovered
        {%{changeset | valid?: true}, nested_recovered_changesets}

      Enum.all?(error_fields, recoverable_field?) ->
        recovered_changeset =
          error_fields
          |> Enum.reduce(changeset, fn field, acc_changeset ->
            put_in(acc_changeset.changes[field], Map.fetch!(fallbacks, field))
          end)
          # Clear the changeset's errors and mark the changeset as valid
          |> Map.merge(%{errors: [], valid?: true})

        {recovered_changeset, nested_recovered_changesets ++ [changeset]}

      true ->
        # The changeset has errors with no configured fallback. The changeset (or its parent, for
        # a nested changeset) will be removed later in the pipeline
        {changeset, nested_recovered_changesets}
    end
  end

  # Check that every changeset in the association and embed changes is valid. An invalid child
  # does not always leave an error entry on its parent, so the parent's error list alone cannot
  # prove that all children have been recovered.
  defp nested_changesets_valid?(changeset, schema_module) do
    (schema_module.__schema__(:associations) ++ schema_module.__schema__(:embeds))
    |> Enum.all?(fn association ->
      changeset.changes
      |> Map.get(association)
      |> List.wrap()
      |> Enum.all?(fn
        %Ecto.Changeset{} = child_changeset -> child_changeset.valid?
        _not_a_changeset -> true
      end)
    end)
  end

  # Recover the changesets in one association's (or embed's) changes, clearing the association's
  # error on the parent once every child changeset is valid. Returns
  # `{changeset, recovered_changesets}`, as `recover_changeset/2` does.
  defp recover_nested_changesets(changeset, association, recover_changeset_errors) do
    case changeset.changes[association] do
      nil ->
        {changeset, []}

      children ->
        # `has_many`, `many_to_many`, and `embeds_many` changes are a list of changesets;
        # `has_one` and `embeds_one` changes are a single changeset. `List.wrap/1` normalizes
        # both into a list for recovery, and the original shape is restored when the changes are
        # updated
        {recovered, recovered_changesets} =
          children
          |> List.wrap()
          |> Enum.map(&recover_changeset(&1, recover_changeset_errors))
          |> Enum.unzip()

        recovered_children = if is_list(children), do: recovered, else: hd(recovered)

        changeset = %{
          changeset
          | changes: Map.put(changeset.changes, association, recovered_children)
        }

        changeset =
          if Enum.all?(recovered, & &1.valid?),
            do: Map.update!(changeset, :errors, &Keyword.delete(&1, association)),
            else: changeset

        {changeset, Enum.concat(recovered_changesets)}
    end
  end
end
