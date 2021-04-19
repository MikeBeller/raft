defmodule Raft do
  @type addr() :: atom()
  @type time() :: non_neg_integer()
  @type log_entry :: {non_neg_integer(), non_neg_integer(), term()}

  def hello do
    :world
  end
end
