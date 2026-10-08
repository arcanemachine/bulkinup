defmodule BulkinupTest do
  use BulkinupDemo.DataCase, async: true

  alias BulkinupDemo.Blog.{Address, Author, Category, Comment, Post, Profile, SocialLink, Tag}
  alias BulkinupDemo.ProxyRepo

  test "upserts rows, updating them on conflict" do
    {:ok, %{upserted: 2, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, [
        %{id: 1, name: "Alice"},
        %{id: 2, name: "Bob"}
      ])

    {:ok, _} =
      Bulkinup.upsert(Repo, Author, [
        %{id: 1, name: "Alicia"},
        %{id: 2, name: "Bobby"}
      ])

    assert Repo.all(from a in Author, order_by: a.id, select: a.name) == ["Alicia", "Bobby"]
  end

  test "chunks parent upserts according to chunk_size" do
    attach_insert_counter("authors")

    attrs_list = Enum.map(1..5, fn id -> %{id: id, name: "author-#{id}"} end)

    {:ok, _} = Bulkinup.upsert(Repo, Author, attrs_list, chunk_size: 2)

    # 5 authors in chunks of 2 -> 3 INSERT queries
    assert count_insert_queries("authors") == 3
    assert Repo.aggregate(Author, :count) == 5
  end

  test "chunks has_many association upserts according to chunk_size" do
    attach_insert_counter("posts")

    attrs_list = [
      %{
        id: 1,
        name: "Alice",
        posts: [
          %{id: 101, author_id: 1, title: "a"},
          %{id: 102, author_id: 1, title: "b"},
          %{id: 103, author_id: 1, title: "c"}
        ]
      },
      %{
        id: 2,
        name: "Bob",
        posts: [
          %{id: 201, author_id: 2, title: "d"},
          %{id: 202, author_id: 2, title: "e"},
          %{id: 203, author_id: 2, title: "f"}
        ]
      }
    ]

    {:ok, _} = Bulkinup.upsert(Repo, Author, attrs_list, chunk_size: 2)

    # 6 posts in chunks of 2 -> 3 INSERT queries
    assert count_insert_queries("posts") == 3
    assert Repo.aggregate(Post, :count) == 6
  end

  test "upserts has_one associations into their own table" do
    attrs_list = [
      %{id: 1, name: "Alice", profile: %{id: 101, author_id: 1, bio: "a"}},
      %{id: 2, name: "Bob", profile: %{id: 102, author_id: 2, bio: "b"}}
    ]

    {:ok, _} = Bulkinup.upsert(Repo, Author, attrs_list)

    assert Repo.all(from p in Profile, order_by: p.id, select: {p.author_id, p.bio}) ==
             [{1, "a"}, {2, "b"}]
  end

  test "skips parents whose has_one association is absent" do
    attrs_list = [
      %{id: 1, name: "Alice", profile: %{id: 101, author_id: 1, bio: "a"}},
      %{id: 2, name: "Bob"}
    ]

    {:ok, _} = Bulkinup.upsert(Repo, Author, attrs_list)

    # Only the author that supplied a profile results in a profile row
    assert Repo.all(from p in Profile, select: p.id) == [101]
    assert Repo.aggregate(Author, :count) == 2
  end

  test "stores embedded data inline on the parent row instead of a separate table" do
    attrs_list = [
      %{
        id: 1,
        name: "Alice",
        address: %{street: "1 Main St", city: "Springfield"},
        social_links: [
          %{label: "website", url: "https://example.com"},
          %{label: "mastodon", url: "https://social.example.com/@alice"}
        ]
      }
    ]

    {:ok, _} = Bulkinup.upsert(Repo, Author, attrs_list)

    author = Repo.get!(Author, 1)
    assert author.address == %Address{street: "1 Main St", city: "Springfield"}

    assert author.social_links == [
             %SocialLink{label: "website", url: "https://example.com"},
             %SocialLink{label: "mastodon", url: "https://social.example.com/@alice"}
           ]
  end

  test "upserts many_to_many related records and join rows, deduplicated" do
    Repo.insert!(%Author{id: 1, name: "Alice"})

    # Both posts share tag 10, which must be upserted (and linked) without duplication
    attrs_list = [
      %{
        id: 1,
        author_id: 1,
        title: "P1",
        tags: [%{id: 10, name: "elixir"}, %{id: 11, name: "ecto"}]
      },
      %{id: 2, author_id: 1, title: "P2", tags: [%{id: 10, name: "elixir"}]}
    ]

    {:ok, _} = Bulkinup.upsert(Repo, Post, attrs_list)

    assert Repo.all(from t in Tag, order_by: t.id, select: {t.id, t.name}) ==
             [{10, "elixir"}, {11, "ecto"}]

    join_rows =
      Repo.all(
        from j in "posts_tags", order_by: [j.post_id, j.tag_id], select: {j.post_id, j.tag_id}
      )

    assert join_rows == [{1, 10}, {1, 11}, {2, 10}]

    # Upserting the same attrs again is idempotent (relies on the join table's unique index)
    {:ok, _} = Bulkinup.upsert(Repo, Post, attrs_list)
    assert Repo.aggregate("posts_tags", :count) == 3
  end

  test "does not upsert nested belongs_to associations; the foreign key rides along on the parent" do
    Repo.insert!(%Author{id: 1, name: "Alice"})
    Repo.insert!(%Category{id: 5, name: "books"})

    # The post supplies both a category_id field and a nested category association
    attrs_list = [
      %{
        id: 1,
        author_id: 1,
        title: "P1",
        category_id: 5,
        category: %{id: 5, name: "updated books"}
      }
    ]

    {:ok, _} = Bulkinup.upsert(Repo, Post, attrs_list)

    # The foreign key is set on the post, but the nested category data is never upserted
    assert Repo.get!(Post, 1).category_id == 5
    assert Repo.all(from c in Category, select: {c.id, c.name}) == [{5, "books"}]
  end

  test "upserts nested associations recursively (has_many -> has_many)" do
    # Comments hang two levels below the author (author -> posts -> comments)
    attrs_list = [
      %{
        id: 1,
        name: "Alice",
        posts: [
          %{
            id: 101,
            author_id: 1,
            title: "a",
            comments: [
              %{id: 1001, post_id: 101, body: "first"},
              %{id: 1002, post_id: 101, body: "second"}
            ]
          }
        ]
      }
    ]

    {:ok, _} = Bulkinup.upsert(Repo, Author, attrs_list)

    assert Repo.all(from c in Comment, order_by: c.id, select: {c.post_id, c.body}) ==
             [{101, "first"}, {101, "second"}]
  end

  test "upserts nested associations recursively (has_many -> many_to_many)" do
    # The posts' tags hang two levels below the author, with tag 10 shared between posts
    attrs_list = [
      %{
        id: 1,
        name: "Alice",
        posts: [
          %{id: 101, author_id: 1, title: "a", tags: [%{id: 10, name: "elixir"}]},
          %{id: 102, author_id: 1, title: "b", tags: [%{id: 10, name: "elixir"}]}
        ]
      }
    ]

    {:ok, _} = Bulkinup.upsert(Repo, Author, attrs_list)

    assert Repo.all(from t in Tag, select: {t.id, t.name}) == [{10, "elixir"}]

    join_rows =
      Repo.all(
        from j in "posts_tags", order_by: [j.post_id, j.tag_id], select: {j.post_id, j.tag_id}
      )

    assert join_rows == [{101, 10}, {102, 10}]
  end

  test "sets placeholder fields on parent and association rows" do
    timestamp = ~U[2026-01-01 00:00:00.000000Z]

    attrs_list = [
      %{id: 1, name: "Alice", posts: [%{id: 101, author_id: 1, title: "a"}]}
    ]

    {:ok, _} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        placeholders: %{
          Author => %{inserted_at: timestamp},
          Post => %{inserted_at: timestamp}
        }
      )

    assert Repo.get!(Author, 1).inserted_at == timestamp
    assert Repo.get!(Post, 101).inserted_at == timestamp
  end

  test "allows a placeholder field to be validate_required" do
    # The authors' required name comes only from the placeholder; the attrs omit it entirely
    attrs_list = [%{id: 1}, %{id: 2}]

    {:ok, %{upserted: 2, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list, placeholders: %{Author => %{name: "Anonymous"}})

    assert Repo.all(from a in Author, select: a.name) == ["Anonymous", "Anonymous"]
  end

  test "allows a placeholder field on a nested association to be validate_required" do
    # The posts' required title comes only from the placeholder
    attrs_list = [
      %{id: 1, name: "Alice", posts: [%{id: 101, author_id: 1}, %{id: 102, author_id: 1}]}
    ]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list, placeholders: %{Post => %{title: "UNTITLED"}})

    assert Repo.all(from p in Post, select: p.title) == ["UNTITLED", "UNTITLED"]
  end

  test "allows a placeholder field on a many_to_many association to be validate_required" do
    Repo.insert!(%Author{id: 1, name: "Alice"})

    # The tags' required name comes only from the placeholder
    attrs_list = [%{id: 1, author_id: 1, title: "P1", tags: [%{id: 10}]}]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Post, attrs_list, placeholders: %{Tag => %{name: "misc"}})

    assert Repo.get!(Tag, 10).name == "misc"
    assert Repo.aggregate("posts_tags", :count) == 1
  end

  test "injects placeholder values into string-keyed attrs" do
    attrs_list = [
      %{"id" => 1, "posts" => [%{"id" => 101, "author_id" => 1}]}
    ]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        placeholders: %{Author => %{name: "Anonymous"}, Post => %{title: "UNTITLED"}}
      )

    assert Repo.get!(Author, 1).name == "Anonymous"
    assert Repo.get!(Post, 101).title == "UNTITLED"
  end

  test "placeholder values replace per-row values in the attrs" do
    attrs_list = [%{id: 1, name: "Bob"}]

    {:ok, _} =
      Bulkinup.upsert(Repo, Author, attrs_list, placeholders: %{Author => %{name: "Anonymous"}})

    assert Repo.get!(Author, 1).name == "Anonymous"
  end

  @tag :capture_log
  test "skips a row whose association attrs cannot be cast when placeholders are configured" do
    # The uncastable posts value is left untouched by placeholder injection, so the changeset
    # reports the cast error and the row is skipped in the usual way
    attrs_list = [%{id: 1, name: "Alice", posts: "garbage"}]

    {:ok, %{upserted: 0, skipped: 1}} =
      Bulkinup.upsert(Repo, Author, attrs_list, placeholders: %{Post => %{title: "UNTITLED"}})

    assert Repo.aggregate(Author, :count) == 0
  end

  test "uses changeset_function when provided" do
    {:ok, _} =
      Bulkinup.upsert(Repo, Author, [%{id: 10, name: "ignored"}],
        changeset_function: :upsert_changeset
      )

    # The alternative changeset only casts :id, so the name never reaches the database
    assert Repo.get!(Author, 10).name == nil
  end

  @tag :capture_log
  test "rejects invalid changesets and reports them as skipped" do
    attrs_list = [
      %{id: 1, name: "valid"},
      %{id: 2}
    ]

    assert {:ok, %{upserted: 1, skipped: 1}} = Bulkinup.upsert(Repo, Author, attrs_list)

    assert Repo.all(from a in Author, select: {a.id, a.name}) == [{1, "valid"}]
  end

  test "accepts a Stream as attrs input, processing it in chunks" do
    attach_insert_counter("authors")

    attrs_stream = Stream.map(1..5, fn id -> %{id: id, name: "author-#{id}"} end)

    {:ok, %{upserted: 5, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_stream, chunk_size: 2)

    # 5 authors in chunks of 2 -> 3 INSERT queries
    assert count_insert_queries("authors") == 3

    assert Repo.all(from a in Author, order_by: a.id, select: a.name) ==
             Enum.map(1..5, &"author-#{&1}")
  end

  test "calls on_skipped once per chunk with the chunk's skipped changesets" do
    test_pid = self()

    # With chunk_size: 2, the first chunk holds one invalid row and the second chunk holds another
    attrs_stream = Stream.map([%{id: 1}, %{id: 2, name: "valid"}, %{id: 3}], & &1)

    {:ok, %{upserted: 1, skipped: 2}} =
      Bulkinup.upsert(Repo, Author, attrs_stream,
        chunk_size: 2,
        on_skipped: &send(test_pid, {:skipped, &1})
      )

    assert_received {:skipped, %{verb: :upsert, schema_module: Author, changesets: [changeset]}}
    assert changeset.changes.id == 1
    assert Keyword.has_key?(changeset.errors, :name)

    assert_received {:skipped, %{changesets: [changeset]}}
    assert changeset.changes.id == 3

    refute_received {:skipped, _}
  end

  test "does not call on_skipped when no rows are skipped" do
    test_pid = self()

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "valid"}],
        on_skipped: &send(test_pid, {:skipped, &1})
      )

    refute_received {:skipped, _}
  end

  test "raises when a handler is not a 1-arity function" do
    for handler_option <- [:on_skipped, :on_recovered] do
      assert_raise ArgumentError, ~r/must be a 1-arity function/, fn ->
        Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alice"}], [{handler_option, fn -> :ok end}])
      end
    end
  end

  test "rolls back the write when a handler raises" do
    attrs_list = [%{id: 1, name: "valid"}, %{id: 2}]

    assert_raise RuntimeError, "handler failed", fn ->
      Bulkinup.upsert(Repo, Author, attrs_list, on_skipped: fn _ -> raise "handler failed" end)
    end

    assert Repo.aggregate(Author, :count) == 0
  end

  test "raises when chunk_size is not a positive integer" do
    assert_raise ArgumentError, ~r/`:chunk_size` option must be a positive integer/, fn ->
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alice"}], chunk_size: 0)
    end
  end

  test "raises when max_concurrency is not a positive integer" do
    assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alice"}], max_concurrency: 0)
    end
  end

  test "raises on unknown options" do
    assert_raise ArgumentError, ~r/unknown option\(s\) \[:chunck_size\]/, fn ->
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alice"}], chunck_size: 100)
    end
  end

  test "raises on a Bulkinup option nested inside insert_all_opts" do
    assert_raise ArgumentError, ~r/no effect inside `:insert_all_opts`/, fn ->
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alice"}],
        insert_all_opts: %{Author => [replace_all_except: [:name]]}
      )
    end
  end

  test "raises when insert_all_opts is not a map" do
    assert_raise ArgumentError, ~r/must be a map/, fn ->
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alice"}],
        insert_all_opts: [on_conflict: :nothing]
      )
    end
  end

  test "allows :timeout and :placeholders inside insert_all_opts" do
    {:ok, _} =
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alice"}],
        insert_all_opts: %{Author => [timeout: 30_000, placeholders: %{}]}
      )

    assert Repo.get!(Author, 1).name == "Alice"
  end

  test "calls on_recovered with the pre-recovery changesets of written rows, at every level" do
    test_pid = self()

    attrs_list = [
      # The author's phone number and the post's missing title are both recovered
      %{
        id: 1,
        name: "Alice",
        phone_number: "INVALID",
        posts: [%{id: 101, author_id: 1}]
      },
      # The post's missing title is recoverable, but the author's missing name is not, so this
      # row is skipped and its recovered post is not reported
      %{id: 2, posts: [%{id: 201, author_id: 2}]}
    ]

    {:ok, %{upserted: 1, skipped: 1}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{
          Author => %{phone_number: "555-1234"},
          Post => %{title: "UNTITLED"}
        },
        on_recovered: &send(test_pid, {:recovered, &1})
      )

    assert_received {:recovered,
                     %{verb: :upsert, schema_module: Author, changesets: recovered_changesets}}

    refute_received {:recovered, _}

    # Each changeset is reported as it was before recovery, with its replaced fields' errors
    recovered_by_schema = Map.new(recovered_changesets, &{&1.data.__struct__, &1})
    assert Map.keys(recovered_by_schema) |> Enum.sort() == Enum.sort([Author, Post])
    assert Keyword.keys(recovered_by_schema[Author].errors) == [:phone_number]
    assert recovered_by_schema[Author].changes.phone_number == "INVALID"
    assert Keyword.keys(recovered_by_schema[Post].errors) == [:title]
    assert recovered_by_schema[Post].changes.id == 101

    assert Repo.get!(Author, 1).phone_number == "555-1234"
  end

  @tag :capture_log
  test "recovers configured changeset errors before upsert" do
    attrs_list = [%{id: 1, name: "Alice", phone_number: "INVALID"}]

    {:ok, _} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{Author => %{phone_number: "555-1234"}}
      )

    assert Repo.get!(Author, 1).phone_number == "555-1234"
  end

  @tag :capture_log
  test "recovers changeset errors in nested association changesets" do
    # The post is missing its required title, so the author's changeset carries a `:posts` error
    attrs_list = [
      %{id: 1, name: "Alice", posts: [%{id: 101, author_id: 1}]}
    ]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{Post => %{title: "UNTITLED"}}
      )

    assert Repo.get!(Post, 101).title == "UNTITLED"
  end

  @tag :capture_log
  test "recovers changeset errors across multiple nesting levels" do
    # The comment is missing its required body, which invalidates the post and the author in
    # turn. Recovering the comment cascades validity back up through both ancestors
    attrs_list = [
      %{
        id: 1,
        name: "Alice",
        phone_number: "oops",
        posts: [
          %{id: 101, author_id: 1, title: "a", comments: [%{id: 1001, post_id: 101}]}
        ]
      }
    ]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{
          Author => %{phone_number: "555-1234"},
          Comment => %{body: "[deleted]"}
        }
      )

    assert Repo.get!(Author, 1).phone_number == "555-1234"
    assert Repo.get!(Comment, 1001).body == "[deleted]"
  end

  @tag :capture_log
  test "recovers changeset errors in a has_one association changeset" do
    # The profile is missing its required bio
    attrs_list = [%{id: 1, name: "Alice", profile: %{id: 101, author_id: 1}}]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{Profile => %{bio: "(none)"}}
      )

    assert Repo.get!(Profile, 101).bio == "(none)"
  end

  @tag :capture_log
  test "recovers changeset errors in a many_to_many association changeset" do
    Repo.insert!(%Author{id: 1, name: "Alice"})

    # The tag is missing its required name
    attrs_list = [%{id: 1, author_id: 1, title: "P1", tags: [%{id: 10}]}]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Post, attrs_list,
        recover_changeset_errors: %{Tag => %{name: "unnamed"}}
      )

    assert Repo.get!(Tag, 10).name == "unnamed"
    assert Repo.aggregate("posts_tags", :count) == 1
  end

  @tag :capture_log
  test "recovers one invalid child among valid siblings" do
    attrs_list = [
      %{
        id: 1,
        name: "Alice",
        posts: [
          %{id: 101, author_id: 1, title: "a"},
          %{id: 102, author_id: 1}
        ]
      }
    ]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{Post => %{title: "UNTITLED"}}
      )

    assert Repo.all(from p in Post, order_by: p.id, select: {p.id, p.title}) ==
             [{101, "a"}, {102, "UNTITLED"}]
  end

  @tag :capture_log
  test "counts recovered and unrecoverable rows independently" do
    # Post 101 is missing only its title (recoverable); post 201 is also missing its author_id,
    # which has no fallback, so Bob's row is skipped
    attrs_list = [
      %{id: 1, name: "Alice", posts: [%{id: 101, author_id: 1}]},
      %{id: 2, name: "Bob", posts: [%{id: 201}]}
    ]

    {:ok, %{upserted: 1, skipped: 1}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{Post => %{title: "UNTITLED"}}
      )

    assert Repo.all(from a in Author, select: a.id) == [1]
    assert Repo.all(from p in Post, select: p.id) == [101]
  end

  @tag :capture_log
  test "does not upsert a recoverable parent whose child is unrecoverable" do
    # The author's phone_number is recoverable, but the post's missing author_id is not. The
    # whole row is skipped: the parent's recoverable error must not be applied partially
    attrs_list = [
      %{id: 1, name: "Alice", phone_number: "oops", posts: [%{id: 101, title: "a"}]}
    ]

    {:ok, %{upserted: 0, skipped: 1}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{
          Author => %{phone_number: "555-1234"},
          Post => %{title: "UNTITLED"}
        }
      )

    assert Repo.aggregate(Author, :count) == 0
    assert Repo.aggregate(Post, :count) == 0
  end

  @tag :capture_log
  test "recovers changeset errors in an embeds_one changeset" do
    # The address is missing its required city
    attrs_list = [%{id: 1, name: "Alice", address: %{street: "1 Main St"}}]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{Address => %{city: "Springfield"}}
      )

    assert Repo.get!(Author, 1).address == %Address{street: "1 Main St", city: "Springfield"}
  end

  @tag :capture_log
  test "recovers changeset errors in an embeds_many changeset" do
    # The second social link is missing its required url
    attrs_list = [
      %{
        id: 1,
        name: "Alice",
        social_links: [
          %{label: "website", url: "https://example.com"},
          %{label: "mastodon"}
        ]
      }
    ]

    {:ok, %{upserted: 1, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{SocialLink => %{url: "https://example.com/unknown"}}
      )

    assert Repo.get!(Author, 1).social_links == [
             %SocialLink{label: "website", url: "https://example.com"},
             %SocialLink{label: "mastodon", url: "https://example.com/unknown"}
           ]
  end

  @tag :capture_log
  test "skips the row when an embedded changeset error has no fallback" do
    # The address is missing its required city, and only :street has a fallback configured
    attrs_list = [%{id: 1, name: "Alice", address: %{street: "1 Main St"}}]

    {:ok, %{upserted: 0, skipped: 1}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{Address => %{street: "unknown"}}
      )

    assert Repo.aggregate(Author, :count) == 0
  end

  @tag :capture_log
  test "does not recover an error on the association field itself" do
    # The posts attr cannot be cast at all, leaving a `:posts` error on the author. A fallback
    # configured for the association field is ignored (a bare value cannot replace changesets)
    attrs_list = [%{id: 1, name: "Alice", posts: "garbage"}]

    {:ok, %{upserted: 0, skipped: 1}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        recover_changeset_errors: %{Author => %{posts: []}}
      )

    assert Repo.aggregate(Author, :count) == 0
  end

  @tag :capture_log
  test "skips the row when a nested changeset error has no fallback" do
    # The post is missing its required author_id, and only :title has a fallback configured
    attrs_list = [
      %{id: 1, name: "Alice", posts: [%{id: 101, title: "a"}]}
    ]

    assert {:ok, %{upserted: 0, skipped: 1}} =
             Bulkinup.upsert(Repo, Author, attrs_list,
               recover_changeset_errors: %{Post => %{title: "UNTITLED"}}
             )

    assert Repo.aggregate(Author, :count) == 0
    assert Repo.aggregate(Post, :count) == 0
  end

  test "applies custom insert_all_opts per schema" do
    insert_all_opts = %{
      Author => [on_conflict: :nothing],
      Post => [on_conflict: {:replace, [:title]}]
    }

    attrs_list = [
      %{id: 1, name: "Alice", posts: [%{id: 101, author_id: 1, title: "a"}]}
    ]

    {:ok, _} = Bulkinup.upsert(Repo, Author, attrs_list, insert_all_opts: insert_all_opts)

    updated_attrs_list = [
      %{id: 1, name: "Alicia", posts: [%{id: 101, author_id: 1, title: "b"}]}
    ]

    {:ok, _} =
      Bulkinup.upsert(Repo, Author, updated_attrs_list, insert_all_opts: insert_all_opts)

    # The author conflict did nothing, while the post conflict replaced the title
    assert Repo.get!(Author, 1).name == "Alice"
    assert Repo.get!(Post, 101).title == "b"
  end

  test "replace_all_except preserves the given fields on conflict" do
    {:ok, _} =
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alice", phone_number: "555-1234"}])

    {:ok, _} =
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alicia", phone_number: "555-9999"}],
        replace_all_except: [:name]
      )

    author = Repo.get!(Author, 1)
    assert author.name == "Alice"
    assert author.phone_number == "555-9999"
  end

  test "uses insert_all_function when provided" do
    attrs_list = [
      %{id: 1, name: "Alice", posts: [%{id: 101, author_id: 1, title: "a"}]}
    ]

    {:ok, _} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        insert_all_function: :insert_all_with_autogenerated_timestamps
      )

    # The custom function (the README recipe) autogenerates the insert timestamps
    assert %DateTime{} = Repo.get!(Author, 1).inserted_at
    assert %DateTime{} = Repo.get!(Post, 101).inserted_at
  end

  test "uses insert_all_module when provided, passing conflict opts and timeout" do
    {:ok, _} =
      Bulkinup.upsert(Repo, Author, [%{id: 1, name: "Alice"}],
        insert_all_module: ProxyRepo,
        timeout: 45_000
      )

    assert Repo.get!(Author, 1).name == "Alice"

    assert_received {:proxy_insert_all, Author, [%{id: 1, name: "Alice"}], opts}
    assert opts[:conflict_target] == [:id]
    assert opts[:on_conflict] == {:replace_all_except, [:id]}
    assert opts[:timeout] == 45_000
  end

  test "rolls back the whole transaction when an association upsert fails" do
    # The post references a nonexistent author, so its foreign key constraint fails
    attrs_list = [
      %{id: 1, name: "Alice", posts: [%{id: 101, author_id: 999, title: "a"}]}
    ]

    assert_raise Postgrex.Error, ~r/foreign_key/, fn ->
      Bulkinup.upsert(Repo, Author, attrs_list)
    end

    # The author was upserted before the post failed, but the transaction rolled it back
    assert Repo.aggregate(Author, :count) == 0
  end

  test "rolls back all chunks when a later chunk fails" do
    # With chunk_size: 1, the first author is upserted in its own chunk before the second
    # author's post fails its foreign key constraint
    attrs_list = [
      %{id: 1, name: "Alice"},
      %{id: 2, name: "Bob", posts: [%{id: 101, author_id: 999, title: "a"}]}
    ]

    assert_raise Postgrex.Error, ~r/foreign_key/, fn ->
      Bulkinup.upsert(Repo, Author, attrs_list, chunk_size: 1)
    end

    assert Repo.aggregate(Author, :count) == 0
  end
end
