defmodule Farmbot.AMQP.ConsoleTransport do
  use GenServer
  use AMQP
  require Farmbot.Logger
  require Logger

  @exchange "amq.topic"

  defstruct [:conn, :chan, :bot, :iex_pid, :gets_pid]
  alias __MODULE__, as: State

  # IEx Callbacks
  def iex_init(_socket, _state) do
    :ok
  end

  def gets(socket, _device, message) do
    send socket, {:gets, self(), to_string(message)}
    receive do
      response -> response
    end
  end

  def puts(socket, _device, message) do
    send socket, {:puts, to_string(message)}
  end

  @doc false
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [name: __MODULE__])
  end

  def init([conn, jwt]) do
    Process.flag(:sensitive, true)
    {:ok, chan}  = AMQP.Channel.open(conn)
    :ok          = Basic.qos(chan, [global: true])
    {:ok, _}     = AMQP.Queue.declare(chan, jwt.bot <> "_remote_console", [auto_delete: true])
    {:ok, _}     = AMQP.Queue.purge(chan, jwt.bot <> "_remote_console")
    :ok          = AMQP.Queue.bind(chan, jwt.bot <> "_remote_console", @exchange, [routing_key: "bot.#{jwt.bot}.remote_console"])
    {:ok, _tag}  = Basic.consume(chan, jwt.bot <> "_remote_console", self(), [no_ack: true])
    {:ok, %State{conn: conn, chan: chan, bot: jwt.bot, iex_pid: nil}}
  end

  # Confirmation sent by the broker after registering this process as a consumer
  def handle_info({:basic_consume_ok, _}, state) do
    socket = self()
    mfa = {__MODULE__, :iex_init, [socket, state]}
    gets = &gets(socket, &1, &2)
    puts = &puts(socket, &1, &2)
    iex_pid = spawn_link fn() ->
      RemoteIEx.Server.start([gets: gets, puts: puts], mfa)
    end
    {:noreply, %{state | iex_pid: iex_pid}}
  end

  # Sent by the broker when the consumer is
  # unexpectedly cancelled (such as after a queue deletion)
  def handle_info({:basic_cancel, _}, state) do
    {:stop, :normal, state}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def handle_info({:basic_cancel_ok, _}, state) do
    {:noreply, state}
  end

  def handle_info({:basic_deliver, payload, %{routing_key: key}}, %{gets_pid: pid} = state) when is_pid(pid) do
    device = state.bot
    ["bot", ^device, "remote_console"] = String.split(key, ".")
    case Farmbot.JSON.decode(payload) do
      {:ok, %{"kind" => "gets_response", "args" => %{"message" => message}}} ->
        send(pid, message)
        {:noreply, %{state | gets_pid: nil}}
      {:ok, unknown} ->
        Farmbot.Logger.warn 3, "Unknown message in from AMQP console: #{inspect unknown}"
        {:noreply, state}
    end
  end

  def handle_info({:basic_deliver, _, _}, state) do
    {:noreply, state}
  end

  def handle_info({:puts, message}, state) do
    publish(state, %{kind: "puts", args: %{message: message}})
    {:noreply, state}
  end

  def handle_info({:gets, pid, message}, state) do
    publish(state, %{kind: "gets", args: %{message: message}})
    {:noreply, %{state | gets_pid: pid}}
  end

  defp publish(state, %{args: %{message: _}, kind: _} = payload) do
    payload = Farmbot.JSON.encode!(payload)
    routing_key = "bot.#{state.bot}.remote_console"
    AMQP.Basic.publish state.chan, @exchange, routing_key, payload
  end
end
