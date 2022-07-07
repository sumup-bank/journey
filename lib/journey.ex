defmodule Journey do
  defstruct data: nil, steps: [], state: :new, result: nil

  alias Journey.Step

  def new() do
    %__MODULE__{}
  end

  def set_data(%__MODULE__{} = journey, data) do
    %__MODULE__{journey | data: data}
  end

  def run(%__MODULE__{} = journey, spec, args \\ []) do
    add_step(journey, {spec, args}, :sync)
  end

  def run_async(%__MODULE__{} = journey, spec, args \\ [], timeout \\ 5000) do
    add_step(journey, {spec, args, timeout}, :async)
  end

  def await(%__MODULE__{steps: steps} = journey) do
    journey
    |> update_steps(Enum.map(steps, &await(&1)))
    |> check_results()
  end

  def await(%Step{spec: {_, _, timeout}, transaction: {func, %Task{} = task}} = step) do
    result =
      case Task.yield(task, timeout) do
        {:ok, result} -> result
        {:exit, error} -> {:error, error}
        nil -> {:error, {:timeout, step}}
      end

    %Step{step | transaction: {func, result}}
  end

  def await(step), do: step

  def finally(%__MODULE__{} = journey, func) do
    func.(await(journey))
  end

  def finally(%__MODULE__{} = journey) do
    finally(journey, fn %{result: result} -> result end)
  end

  defp add_step(%__MODULE__{} = journey, spec, :sync = type) do
    journey
    |> await()
    |> mk_step(spec, type)
    |> await()
  end

  defp add_step(%__MODULE__{} = journey, spec, type) do
    mk_step(journey, spec, type)
  end

  defp mk_step(%__MODULE__{state: :failed} = journey, _, _), do: journey

  defp mk_step(%__MODULE__{} = journey, spec, type) do
    {transaction, compensation} = get_funcs(spec)

    update_steps(
      journey,
      journey.steps ++
        [
          %Step{
            spec: spec,
            compensation: {compensation, nil, :not_called},
            transaction: {transaction, call(transaction, journey, type)}
          }
        ]
    )
  end

  defguardp is_valid_function(func) when is_function(func, 0) or is_function(func, 1)
  defguardp is_ok(result) when result == :ok or elem(result, 0) == :ok

  defp call(transaction, journey, :async) do
    Task.async(fn -> call(transaction, journey, :sync) end)
  end

  defp call(func, journey, type) when is_function(func, 0) do
    call(fn _ -> func.() end, journey, type)
  end

  defp call(func, %__MODULE__{} = journey, _) when is_function(func, 1) do
    try do
      func.(journey)
    catch
      :error,reason -> {:error, reason}
      error,reason -> {:error, {error, reason}}
    end
  end

  defp get_funcs({spec, args}), do: get_funcs({spec, args, 0})

  defp get_funcs({func, _, _}) when is_function(func) do
    extract_funcs(func.())
  end

  defp get_funcs({{module, function_name}, args, _}) do
    extract_funcs(apply(module, function_name, args))
  end

  defp extract_funcs({transaction, compensation} = funcs)
       when is_valid_function(transaction) and is_valid_function(compensation),
       do: funcs

  defp extract_funcs(transaction) when is_valid_function(transaction), do: {transaction, nil}

  defp check_results(%__MODULE__{steps: steps} = journey) do
    with true <-
           Enum.any?(steps, fn
             %Step{transaction: {_, result}} when is_ok(result) -> false
             _ -> true
           end) do
      rollback(journey)
    else
      _ -> journey
    end
  end

  defp rollback(%__MODULE__{steps: steps} = journey) do
    journey = %__MODULE__{journey | state: :failed}

    steps =
      steps
      |> Enum.reverse()
      |> Enum.map(&call_compensation(&1, journey))
      |> Enum.reverse()

    %__MODULE__{journey | steps: steps}
  end

  defp call_compensation(
         %Step{compensation: {func, _, :not_called}, transaction: {_, result}} = step,
         journey
       )
       when is_function(func) and is_ok(result) do
    %Step{step | compensation: {func, call(func, journey, :sync), :called}}
  end

  defp call_compensation(step, _journey), do: step

  defp update_steps(%__MODULE__{} = journey, []), do: journey

  defp update_steps(%__MODULE__{} = journey, steps) do
    with true <-
           Enum.any?(steps, fn
             %Step{transaction: {_, %Task{}}} -> true
             _ -> false
           end) do
      %__MODULE__{journey | steps: steps, state: :running, result: nil}
    else
      _ ->
        %Step{transaction: {_, result}} = List.last(steps)
        %__MODULE__{journey | steps: steps, state: :done, result: result}
    end
  end
end
