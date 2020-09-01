defmodule JourneyTest do
  use ExUnit.Case

  require Logger
  alias Journey.Step

  describe "with a new journey" do
    setup do
      %{journey: Journey.new()}
    end

    test "set a data in context", %{journey: journey} do
      assert %Journey{data: 1} = Journey.set_data(journey, 1)
    end

    test "add step and run it", %{journey: journey} do
      spec = {__MODULE__, :sync_step}

      %Journey{
        steps: [step],
        result: :ok,
        state: :done
      } = Journey.run(journey, spec, [:ok])

      assert %Step{spec: {^spec, [:ok]}, transaction: {_, :ok}} = step
    end

    test "add async step and run it", %{journey: journey} do
      journey =
        journey
        |> Journey.run(fn -> sync_step() end)
        |> Journey.run_async({__MODULE__, :async_step}, [3, :ok])

      assert %Journey{steps: [sync, async], state: :running, result: nil} = journey
      assert %Step{transaction: {_, :ok}} = sync
      assert %Step{transaction: {_, %Task{owner: self}}} = async
    end

    test "sync step wait for async steps", %{journey: journey} do
      journey =
        journey
        |> Journey.run(fn -> sync_step() end)
        |> Journey.run_async({__MODULE__, :async_step}, [3, :ok])
        |> Journey.run_async({__MODULE__, :async_step}, [5, :ok])
        |> Journey.run(fn -> sync_step() end)

      assert %Journey{steps: steps, state: :done, result: :ok} = journey

      assert [
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, nil, :not_called}
               },
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, nil, :not_called}
               },
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, nil, :not_called}
               },
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, nil, :not_called}
               }
             ] = steps
    end

    test "use await to wait all transactions", %{journey: journey} do
      result =
        journey
        |> Journey.run(fn -> sync_step() end)
        |> Journey.run_async({__MODULE__, :async_step}, [3, :ok])
        |> Journey.run_async({__MODULE__, :async_step}, [5, {:ok, :ended}])

      assert %Journey{
               state: :running,
               result: nil,
               steps: [_, _, %Step{transaction: {_, %Task{}}}]
             } = result

      result = Journey.await(result)

      assert %Journey{
               state: :done,
               result: {:ok, :ended},
               steps: [_, _, %Step{transaction: {_, {:ok, :ended}}}]
             } = result
    end

    test "use finally to return last result", %{journey: journey} do
      result =
        journey
        |> Journey.run(fn -> sync_step() end)
        |> Journey.run_async({__MODULE__, :async_step}, [3, :ok])
        |> Journey.run_async({__MODULE__, :async_step}, [5, :ended])
        |> Journey.finally()

      assert :ended = result
    end

    test "use finally to format result", %{journey: journey} do
      result =
        journey
        |> Journey.run(fn -> sync_step() end)
        |> Journey.run_async({__MODULE__, :async_step}, [3, :ok])
        |> Journey.run_async({__MODULE__, :async_step}, [5, :ended])
        |> Journey.finally(fn
          %Journey{steps: steps} -> List.last(steps)
        end)

      assert %Step{transaction: {_, :ended}} = result
    end

    test "run compensation if sync transaction fail", %{journey: journey} do
      result =
        journey
        |> Journey.run_async({__MODULE__, :test_compensation}, [:ok, self()])
        |> Journey.run({__MODULE__, :test_compensation}, [:error, self()])
        # Step will not add because before step will failed
        |> Journey.run_async({__MODULE__, :test_compensation}, [:ok, self()])

      assert %Journey{result: :error, state: :failed, steps: steps} = result

      assert [
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, :ok, :called}
               },
               %Step{
                 transaction: {_, :error},
                 compensation: {_, nil, :not_called}
               }
             ] = steps

      assert_receive :transaction_called
      assert_receive :compensation_called
      refute_receive :compensation_called
    end

    test "run compensation if async transaction fail", %{journey: journey} do
      fn_sleep = fn ->
        :timer.sleep(300)
        :ok
      end

      result =
        journey
        |> Journey.run({__MODULE__, :test_compensation}, [{:ok, :any}, self()])
        |> Journey.run_async({__MODULE__, :test_compensation}, [:ok, self()])
        |> Journey.run_async({__MODULE__, :test_compensation}, [{:ok, :any}, self()])
        |> Journey.run({__MODULE__, :test_compensation}, [:ok, self()])
        |> Journey.run_async({__MODULE__, :test_compensation}, [fn_sleep, self()])
        |> Journey.run_async({__MODULE__, :test_compensation}, [{:error, :any}, self()])
        # Step will not add because before step will failed
        |> Journey.run({__MODULE__, :test_compensation}, [{:ok, :any}, self()])

      assert %Journey{result: {:error, :any}, state: :failed, steps: steps} = result

      assert [
               %Step{
                 transaction: {_, {:ok, :any}},
                 compensation: {_, :ok, :called}
               },
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, :ok, :called}
               },
               %Step{
                 transaction: {_, {:ok, :any}},
                 compensation: {_, :ok, :called}
               },
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, :ok, :called}
               },
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, :ok, :called}
               },
               %Step{
                 transaction: {_, {:error, :any}},
                 compensation: {_, nil, :not_called}
               }
             ] = steps

      # Only call once each transaction
      for _ <- 1..6, do: assert_receive :transaction_called
      for _ <- 1..5, do: assert_receive :compensation_called
      refute_receive :compensation_called
    end

    test "run compensation if sync transaction raise a exception", %{journey: journey} do
      result =
        journey
        |> Journey.run_async({__MODULE__, :test_compensation}, [:ok, self()])
        |> Journey.run({__MODULE__, :test_compensation}, [fn -> raise "Any error" end, self()])
        # Step will not add because before step will failed
        |> Journey.run_async({__MODULE__, :test_compensation}, [:ok, self()])

      error = {:error, %RuntimeError{message: "Any error"}}
      assert %Journey{result: ^error, state: :failed, steps: steps} = result

      assert [
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, :ok, :called}
               },
               %Step{
                 transaction: {_, ^error},
                 compensation: {_, nil, :not_called}
               }
             ] = steps

      assert_receive :transaction_called
      assert_receive :compensation_called
      refute_receive :compensation_called
    end

    test "run compensation if async transaction raise a exception", %{journey: journey} do
      result =
        journey
        |> Journey.run_async({__MODULE__, :test_compensation}, [:ok, self()])
        |> Journey.run_async({__MODULE__, :test_compensation}, [fn -> raise "Any error" end, self()])
        # Step will not add because before step will failed
        |> Journey.run({__MODULE__, :test_compensation}, [:ok, self()])

      error = {:error, %RuntimeError{message: "Any error"}}
      assert %Journey{result: ^error, state: :failed, steps: steps} = result

      assert [
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, :ok, :called}
               },
               %Step{
                 transaction: {_, ^error},
                 compensation: {_, nil, :not_called}
               }
             ] = steps

      assert_receive :transaction_called
      assert_receive :compensation_called
      refute_receive :compensation_called
    end

    test "run compensation if await a async transaction ended with timeout", %{journey: journey} do
      result =
        journey
        |> Journey.run_async({__MODULE__, :test_compensation}, [:ok, self()])
        |> Journey.run_async({__MODULE__, :test_compensation}, [fn -> :timer.sleep(500) end, self()], 50)
        # Step will not be added because previous step has failed due to timeout
        |> Journey.run({__MODULE__, :test_compensation}, [:ok, self()])

      assert %Journey{result: error, state: :failed, steps: steps} = result
      assert {:error, {:timeout, %Step{spec: {{__MODULE__, :test_compensation}, _, 50}}}} = error

      assert [
               %Step{
                 transaction: {_, :ok},
                 compensation: {_, :ok, :called}
               },
               %Step{
                 transaction: {_, {:error, {:timeout, %Step{}}}},
                 compensation: {_, nil, :not_called}
               }
             ] = steps

      assert_receive :transaction_called
      assert_receive :compensation_called
      refute_receive :compensation_called
    end
  end

  def test_compensation(result, pid) when not is_function(result) do
    test_compensation(fn -> result end, pid)
  end

  def test_compensation(result, pid) do
    {
      fn ->
        send(pid, :transaction_called)
        result.()
      end,
      fn ->
        send(pid, :compensation_called)
        :ok
      end
    }
  end

  def async_step(time \\ 1, result \\ :ok) do
    fn ->
      :timer.sleep(time)
      result
    end
  end

  def sync_step(result \\ :ok) do
    fn -> result end
  end
end
