defmodule Raft.Server do
  use GenServer
  alias Raft.Consensus
  require Logger

  @type addr :: Raft.addr
  @type time :: Raft.time

  @rand_range 4503599627370496  # 2 ^ 52 (:rand's precision)

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    cons = Keyword.get(opts, :cons) || Consensus.new(name)
    cons = %{cons | me: name}
    log = Keyword.get(opts, :log) || []
    drop = Keyword.get(opts, :drop) || []
    state = %{cons: cons, timers: %{}, log: log, drop: drop, name: name}
    GenServer.start_link(__MODULE__, state, name: name)
  end

  @spec ev(addr(), Consensus.event()) :: :ok 
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
    put_in(state.timers[which], {ref, id})
  end

  def do_send(to, msg, state) do
    # &&& implement dropping
    if :send in state.log do
      Logger.info "#{inspect state.name} SEND to: #{inspect to} msg: #{inspect msg}"
    end
    GenServer.cast(to, msg)
  end

  def do_action({:send, nodes, msg}, state) do
    nodes
    |> Enum.each(fn n -> do_send(n, msg, state) end)
    state
  end

  def do_action({:set_timer, which, time}, state) do
    set_timer(state, which, time)
  end

  def do_action({:cancel_timer, which}, state) do
    cancel_timer(state, which)
  end

  def do_actions(actions, state) do
    Enum.reduce(actions, state, &do_action/2)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast(msg, state) do
    if :recv in state.log do
      Logger.info "#{inspect state.name} RECV: #{inspect msg}"
    end
    {cons, actions} = Consensus.ev(state.cons, msg)
    state = do_actions(actions, %{state | cons: cons})
    {:noreply, state}
  end

  @impl true
  def handle_info({:timeout, which, id}, state) do
    if :timeout in state.log do
      Logger.info "#{inspect state.name} EXPIRY: #{inspect which}"
    end
    case Map.get(state.timers, which) do
      {_ref, rid} when id == rid ->
        state = put_in(state.timers[which], nil)
        {cons, actions} = Consensus.ev(state.cons, {:timeout, which})
        state = do_actions(actions, %{state | cons: cons})
        {:noreply, state}
      _ ->
        Logger.info "Ignoring old timer: #{which} #{id}"
        {:noreply, state}
    end
  end
end
