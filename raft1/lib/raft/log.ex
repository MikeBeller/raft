defmodule Raft.Log do

  defmodule Entry do
    defstruct [:index, :term, :type, :data]

    @type t :: %__MODULE__{
      index: non_neg_integer(),
      term: non_neg_integer(),
      type: :noop | :cmd,
      data: term(),
    }
  end

  @type t :: list(Entry.t)

  @spec new() :: t
  def new(), do: []

  @spec get_entry(t, non_neg_integer()) :: {:ok, Entry.t} | {:error, :not_found}
  def get_entry(log, ind) do
    case Enum.find(log, fn entry -> entry.index == ind end) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @spec last_index(t) :: non_neg_integer()
  def last_index([]), do: 0
  def last_index([e | _rest]), do: e.index

  @spec last_term(t) :: non_neg_integer()
  def last_term([]), do: 0
  def last_term([e | _rest]), do: e.term

  @spec append(t, non_neg_integer(), :noop | :cmd, term()) :: t
  def append(log, term, type, data) do
    ind = last_index(log)
    entry = %Entry{index: ind + 1, term: term, type: type, data: data}
    [entry | log]
  end
end
