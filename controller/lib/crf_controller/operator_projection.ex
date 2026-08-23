defmodule CrfController.OperatorProjection do
  @moduledoc "Bounded, secret-free fleet projection delivered only to authenticated nodes."

  alias CrfController.OperatorSnapshot

  def build(controller_instance_id, now_unix_ms, snapshot_fun \\ &OperatorSnapshot.snapshot/0)
      when is_binary(controller_instance_id) and is_integer(now_unix_ms) and now_unix_ms > 0 do
    snapshot_fun.()
    |> Map.put(:controller_instance_id, controller_instance_id)
    |> Map.put(:observed_at_unix_ms, now_unix_ms)
    |> json_value()
  end

  defp json_value(nil), do: :null
  defp json_value(true), do: true
  defp json_value(false), do: false
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value) when is_binary(value) or is_number(value), do: value
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_value(nested)} end)
  end
end
