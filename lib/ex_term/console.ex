defmodule ExTerm.Console do
  @moduledoc """
  A datastructure which describes in-memory storage of console information.

  Console information consists of the following:

  - buffer of all rows/columns so far.
  - view window sizing metadata.
  - cursor location.
  - current ANSI styling metadata.

  You may also store custom metadata into console.

  Console is backed by an ets table.  Access functions are designed to operate
  across a cluster.  Note that console is not backed by a process, but it is the
  responsibility of a process; if that process dies, the console will get destroyed,
  and by default mutating functions cannot be called from other processes.
  """

  use Phoenix.Component
  use MatchSpec

  alias ExTerm.Console.Cell
  alias ExTerm.Console.StringTracker
  alias ExTerm.Style

  import ExTerm.Console.Helpers

  @type permission :: :private | :protected | :public
  @opaque t ::
            {:private | :protected, pid, :ets.table()}
            | {:public, pid, :ets.table(), :atomics.atomics_ref()}
  @type location :: {pos_integer(), pos_integer()}
  @type update ::
          {:xterm_console_update, from :: location, to :: location, cursor :: location,
           last_cell :: location}
  @type cellinfo :: {location, Cell.t()}

  # message typing
  @type update_msg :: update
  defmacro update_msg(from: from, to: to, cursor: cursor, last_cell: last_cell) do
    quote do
      {:xterm_console_update, unquote(from), unquote(to), unquote(cursor), unquote(last_cell)}
    end
  end

  ############################################################################
  ## rendering function

  def render(assigns) do
    ~H"""
    <div id="exterm-console" phx-update="append">
      <Cell.render contenteditable="false" :for={cell <- @cells} cell={cell} cursor={@cursor} prompt={@prompt}/>
    </div>
    """
  end

  #############################################################################
  ## API

  #############################################################################
  ## GUARDS

  defguard permission(console) when elem(console, 0)

  defguard custodian(console) when elem(console, 1)

  defguard spinlock(console) when elem(console, 3)

  defguard is_access_ok(console)
           when permission(console) in [:public, :protected] or self() === custodian(console)

  defguard is_mutate_ok(console)
           when permission(console) === :public or self() === custodian(console)

  defguard is_local(console) when node(custodian(console)) === node()

  defp table(console), do: elem(console, 2)

  #############################################################################
  ## CONSOLE ETS interactions

  @spec new(keyword) :: t
  def new(opts \\ []) do
    permission = Keyword.get(opts, :permission, :protected)
    {rows, columns} = layout = Keyword.get(opts, :layout, {24, 80})
    update_handler = Keyword.get(opts, :handle_update)
    table = :ets.new(__MODULE__, [permission, :ordered_set])

    console =
      case permission do
        :public -> {:public, self(), table, :atomics.new(1, signed: false)}
        _ -> {permission, self(), table}
      end

    transaction(console, :mutate) do
      console
      |> put_metadata(
        layout: layout,
        cursor: {1, 1},
        style: %Style{},
        handle_update: update_handler
      )
    end
  end

  @spec layout(t) :: location
  def layout(console) do
    transaction(console, :access) do
      get_metadata(console, :layout)
    end
  end

  @spec cursor(t) :: location
  def cursor(console) do
    transaction(console, :access) do
      get_metadata(console, :cursor)
    end
  end

  @spec style(t) :: Style.t()
  def style(console) do
    transaction(console, :access) do
      get_metadata(console, :style)
    end
  end

  # basic access functions

  defmatchspecp get_ms({key, value}) do
    {{^key, ^value}, cell} -> cell
  end

  @spec get(t, location) :: nil | Cell.t()
  def get(console, location) do
    console
    |> select(get_ms(location))
    |> case do
      [cell] -> cell
      [] -> nil
    end
  end

  defmatchspecp metadata_ms(key) when is_atom(key) do
    {^key, value} -> value
  end

  defmatchspecp metadata_ms(keys) when is_list(keys) do
    tuple = {key, _} when key in keys -> tuple
  end

  @spec get_metadata(t, atom | [atom]) :: term
  @doc """
  obtains a single key metadata or a list of keys.

  Note that if you provide a list of keys the values will be returned as a
  keyword list, in erlang term order of the keys.
  """
  def get_metadata(console, key) do
    case select(console, metadata_ms(key)) do
      list when is_atom(key) -> List.first(list)
      list -> list
    end
  end

  # basic mutations

  @spec put_metadata(t, atom, term) :: t
  def put_metadata(console, key, value) do
    insert(console, [{key, value}])
  end

  @spec put_metadata(t, keyword) :: t
  def put_metadata(console, keyword) do
    insert(console, keyword)
  end

  @spec delete_metadata(t, atom) :: t
  def delete_metadata(console, key) do
    delete(console, key)
  end

  @spec put_cell(t, location, Cell.t()) :: t
  def put_cell(console, location, char) do
    last_cell = last_cell(console)

    console
    |> insert({location, char})
    |> update_with(location, location, last_cell)
  end

  # compound operations
  defmatchspecp bump_rows_after(line) do
    {{row, column}, cell} when row >= line -> {{row + 1, column}, cell}
  end

  @spec new_row(t, pos_integer() | :end) :: t
  def new_row(console, insertion_at \\ :end)

  def new_row(console, :end) do
    {row, _} = last_cell(console)
    new_row = row + 1
    {_rows, columns} = get_metadata(console, :layout)

    # note it's okay to put that last one out of order because ets will
    # order it correctly.
    console
    |> insert(make_blank_row(new_row, columns))
    |> update_with({new_row, 1}, {new_row, columns + 1}, {new_row, columns})
  end

  def new_row(console, line) when is_integer(line) do
    new_row_columns = columns(console, line)
    {last_row, last_column} = last_cell(console)

    moved_rows = select(console, bump_rows_after(line))

    update =
      line
      |> make_blank_row(new_row_columns)
      |> Enum.reverse(moved_rows)

    console
    |> insert(update)
    |> update_with({line, 1}, {last_row + 1, last_column}, {last_row + 1, last_column - 1})
  end

  @spec put_string(t, String.t()) :: t
  def put_string(console, string) do
    console
    |> StringTracker.new()
    |> StringTracker.put_string_rows(string)
    |> StringTracker.send_update(with_cursor: true)
    |> Map.get(:console)
  end

  @spec insert_string(t, String.t(), row :: pos_integer()) :: t
  @doc """
  `inserts` a string at a certain row.

  This will "push down" as many lines as is necessary to insert the string.
  If the current cursor precedes the insertion point, it will be unaffected.
  If the current cursor is after the insertion point, it will be displaced
  as many lines as makes sense.  ANSI "cursor" movements in the context of
  this insertion are PINNED to the full lines of the inserted content.

  An ANSI "clear" operation only clears the region inserted so far.
  """
  def insert_string(console, string, row) do
    console
    |> StringTracker.new(row)
    |> StringTracker.insert_string_rows(string)
    |> StringTracker.send_update()
    |> Map.get(:console)
  end

  defmatchspecp cell_range_ms(row, column_start, row, column_end) do
    tuple = {{^row, column}, _} when column >= column_start and column <= column_end -> tuple
  end

  defmatchspecp cell_range_ms(row_start, column_start, row_end, column_end)
                when row_start + 1 === row_end do
    tuple = {{^row_start, column}, cell} when column >= column_start ->
      tuple

    tuple = {{^row_end, column}, _} when column <= column_end ->
      tuple
  end

  defmatchspecp cell_range_ms(row_start, column_start, row_end, column_end) do
    tuple = {{^row_start, column}, cell} when column >= column_start ->
      tuple

    tuple = {{^row_end, column}, _} when column <= column_end ->
      tuple

    tuple = {{row, column}, cell} when row > row_start and row < row_end ->
      tuple
  end

  @spec cells(t, location, location) :: [cellinfo]
  def cells(console, {row_start, column_start}, {row_end, column_end}) do
    select(console, cell_range_ms(row_start, column_start, row_end, column_end))
  end

  @spec move_cursor(t(), any) :: t()
  def move_cursor(console, new_cursor) do
    old_cursor = get_metadata(console, :cursor)
    last_cell = last_cell(console)

    console
    |> put_metadata(:cursor, new_cursor)
    |> update_with(old_cursor, old_cursor, new_cursor, last_cell)
    |> update_with(new_cursor, new_cursor, new_cursor, last_cell)
  end

  # functional utilities

  @spec update_with(
          t,
          from :: location,
          to :: location,
          cursor :: location,
          last_cell :: location
        ) :: t
  @spec update_with(t, from :: location, to :: location, last_cell :: location) :: t
  defp update_with(console, from, to, last_cell) do
    cursor = get_metadata(console, :cursor)
    update_with(console, from, to, cursor, last_cell)
  end

  defp update_with(console, from, to, cursor, last_cell) do
    case get_metadata(console, :handle_update) do
      fun when is_function(fun, 1) ->
        fun.(update_msg(from: from, to: to, cursor: cursor, last_cell: last_cell))

      nil ->
        :ok

      other ->
        raise "invalid update handler, expected arity 1 fun, got #{inspect(other)}"
    end

    console
  end

  defmatchspecp column_count_ms(row) do
    {{^row, _}, cell} when cell.char !== "\n" -> true
  end

  defmatchspecp full_row_ms(row, true) do
    tuple = {{^row, _}, _} -> tuple
  end

  defmatchspecp full_row_ms(row, false) do
    tuple = {{^row, _}, cell} when cell.char !== "\n" -> tuple
  end

  @spec columns(t, row :: pos_integer) :: non_neg_integer
  @doc """
  returns the number of columns in a given row.

  Does not include the sentinel in the final count.

  If the row doesn't exist, returns 0.
  """
  defaccess columns(console, row) do
    console
    |> table()
    |> :ets.select_count(column_count_ms(row))
  end

  @spec full_row(t, row :: pos_integer, with_sentinel? :: boolean) :: [cellinfo]
  @doc """
  returns a full row, in ascending order.

  May include the sentinel, if `with_sentinel?` is `true` (defaults to `false`)
  """
  def full_row(console, row, with_sentinel? \\ false) do
    select(console, full_row_ms(row, with_sentinel?))
  end

  @spec last_cell(t) :: location
  @doc """
  returns the last location on the console.

  Does NOT include the sentinel.  There is always guaranteed to be a sentinel
  on the end of the cell.

  If the table is empty and only contains metadata, returns `{0, 0}`
  """
  defaccess last_cell(console) do
    # the last item in the table encodes the last row because the ordered
    # set is ordered based on erlang term order and erlang term order puts tuples
    # behind atoms, which are the only two types in the table.
    console
    |> table()
    |> :ets.last()
    |> case do
      {row, column} -> {row, column - 1}
      metadata when is_atom(metadata) -> {0, 0}
    end
  end

  # generic access functions

  @spec select(t, :ets.match_spec()) :: [tuple]
  defaccess select(console, ms) do
    console
    |> table()
    |> :ets.select(ms)
  end

  @spec insert(t, tuple | [tuple]) :: t
  defmutate insert(console, content) do
    console
    |> table()
    |> :ets.insert(content)

    console
  end

  @spec delete(t, atom) :: t
  defmutate delete(console, key) do
    console
    |> table
    |> :ets.delete(key)

    console
  end

  # other commonly usable functions
  def make_blank_row(row, columns) do
    [
      {{row, columns + 1}, Cell.sentinel()}
      | for column <- 1..columns do
          {{row, column}, %Cell{}}
        end
    ]
  end
end
