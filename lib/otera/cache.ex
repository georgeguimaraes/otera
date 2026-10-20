defmodule Otera.Cache do
  @moduledoc """
  A cache of parsed templates across renders, like the template cache of a Jinja2 `Environment`.

  Without a cache, Otera loads and parses each template once in a render. With the `:cache` option of `Otera.load/2` and `Otera.render/3`, it keeps the parsed templates of a loader for the next renders. The cache is an ETS table that a process owns, so start it in the supervision tree of your application:

      children = [
        {Otera.Cache, name: MyApp.Templates}
      ]

  Then give its name with the loader:

      opts = [loader: Otera.Loader.file_system("priv/templates"), cache: MyApp.Templates]
      {:ok, template} = Otera.load("page.html", opts)
      Otera.render(template, %{title: "Home"}, opts)

  The cache keeps a template for each loader, name and parse options (`:trim_blocks`, `:lstrip_blocks`, `:keep_trailing_newline` and the names of the custom filters and tests). Like the auto reload of Jinja2, it checks a template before it uses it:

    * A template of `Otera.Loader.file_system/1` loads again when the modification time or the size of its file changes. The time has a resolution of one second.
    * A template of a map loads again when the map has another source for its name, like the `DictLoader` of Jinja2.
    * A template of a function loads again when the function gave an `uptodate` function with the source and that function returns false, like the `FunctionLoader` of Jinja2. Without it, the template stays until `clear/1`.

  These checks have a cost: a file system loader reads the status of each file at each render. Like `auto_reload=False` in Jinja2, start the cache with `auto_reload: false` to use each template without a check until `clear/1`:

      {Otera.Cache, name: MyApp.Templates, auto_reload: false}
  """

  use GenServer

  # The table keeps the auto_reload option under this key, which clear/1 keeps.
  @config :"$otera_auto_reload"

  @doc """
  Starts the process that owns the cache.

  Options:

    * `:name` - the name of the cache, which the `:cache` option takes. Required.
    * `:auto_reload` - checks if a template changed before each use. The default is `true`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, {name, Keyword.get(opts, :auto_reload, true)}, name: name)
  end

  @impl true
  def init({name, auto_reload}) do
    :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(name, {@config, auto_reload})
    {:ok, name}
  end

  @doc """
  Removes all the templates of the cache `cache`.
  """
  @spec clear(atom) :: :ok
  def clear(cache) do
    :ets.match_delete(cache, {:_, :_, :_})
    :ok
  end

  @doc """
  Returns the template under `key` when `fresh?` returns true for its freshness check, or when the cache has `auto_reload: false`. Else runs `load`, which returns a template and its freshness check, and keeps them.
  """
  @spec fetch(atom, term, (term -> boolean), (-> {Otera.Template.t(), term})) ::
          Otera.Template.t()
  def fetch(cache, key, fresh?, load) do
    case :ets.lookup(cache, key) do
      [{^key, template, check}] ->
        if not auto_reload?(cache) or fresh?.(check),
          do: template,
          else: store(cache, key, load.())

      [] ->
        store(cache, key, load.())
    end
  end

  defp auto_reload?(cache), do: :ets.lookup_element(cache, @config, 2)

  defp store(cache, key, {template, check}) do
    :ets.insert(cache, {key, template, check})
    template
  end
end
