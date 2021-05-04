defmodule Raft.Server do
  use GenServer
  alias Raft.Consensus
  require Logger

  @rand_range 4503599627370496  # 2 ^ 52 (:rand's precision)

  def start_link(%Consensus.Data{} = cons) do
    name = cons.me
    state = %{cons: cons, timers: %{}}
    GenServer.start_link(__MODULE__, state, name: name)
  end

  def start_link(me) do
    start_link(Consensus.new(me))
  end

  def ev(me, msg) do
    GenServer.cast(me, msg)
  end

  def cancel_timer(state, which) do
    case Map.get(state.timers, which) do
      nil -> nil
      {ref, _id} -> Process.cancel_timer(ref)
    end
    put_in(state.timers[which], nil)
  end

  def set_timer(state, which, time) do
    state = cancel_timer(state, which)
    id = :rand.uniform(@rand_range)
    ref = Process.send_after(self(), {:timeout, which, id}, time)
    put_in(state.timers[which], ref)
  end

  def do_action({:send, nodes, msg}, state) do
    nodes
    |> Enum.each(fn n -> send n, msg end)
    state
  end

  def do_action({:set_timer, which, time}, state) do
    set_timer(state, which, time)
  end

  def do_action({:cancel_timer, which}, state) do
    cancel_timer(state, which)
  end

  def do_actions(state, actions) do
    Enum.reduce(actions, state, &do_action/2)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast(msg, state) do
    {cons, actions} = Consensus.ev(state.cons, msg)
    state = do_actions(actions, %{state | cons: cons})
    {:noreply, state}
  end

  @impl true
  def handle_info({:timeout, which, id}, state) do
    case Map.get(state.timers, which) do
      {_ref, rid} when id == rid ->
        state = put_in(state.timers[which], nil)
        {cons, actions} = Consensus.ev(state.cons, {:timeout, which})
        state = do_actions(actions, %{state | cons: cons})
        {:noreply, state}
      _ -> {:noreply, state}  # ignore old timer
    end
  end
end
