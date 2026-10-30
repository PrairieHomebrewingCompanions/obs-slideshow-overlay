defmodule ObsSlideshowOverlay.Csv do
  @moduledoc """
  Reads a CSV file (a spreadsheet export, a sign-up form's responses, ...)
  into name list entries, from the columns the user picks: name columns
  joined with spaces ("First" + "Last"), detail columns with " · ".

  Only the picked columns go any further: exports often carry email
  addresses and other details that have no place on a slide.
  """

  alias NimbleCSV.RFC4180, as: CSV

  defstruct headers: [], rows: []

  @doc """
  The file's rows, the first as `headers`. Every row is padded to the same
  number of columns, and blank rows are dropped.
  """
  def parse(text) do
    rows =
      text
      |> String.trim_leading("﻿")
      |> CSV.parse_string(skip_headers: false)
      |> Enum.map(fn row -> Enum.map(row, &String.trim/1) end)
      |> Enum.reject(fn row -> Enum.all?(row, &(&1 == "")) end)

    case rows do
      [] ->
        {:error, "That file is empty"}

      [headers | rest] ->
        width = rows |> Enum.map(&length/1) |> Enum.max()
        pad = fn row -> row ++ List.duplicate("", width - length(row)) end
        {:ok, %__MODULE__{headers: pad.(headers), rows: Enum.map(rest, pad)}}
    end
  rescue
    NimbleCSV.ParseError -> {:error, "That file isn't a CSV file"}
  end

  @doc """
  The columns that most likely hold names: one called "Name", else "First"
  and "Last" name columns, else the first column.
  """
  def guess_name_columns(%__MODULE__{headers: headers}) do
    find = fn pattern -> Enum.find_index(headers, &(&1 =~ pattern)) end
    name = find.(~r/^(full\s*)?name$/i)
    first = find.(~r/first|given/i)
    last = find.(~r/last|surname|family/i)

    cond do
      name -> [name]
      first && last -> [first, last]
      true -> [0]
    end
  end

  @doc """
  `[{name, detail}]` from the rows (and the headers row too, when it isn't
  headers), skipping rows without a name.
  """
  def entries(%__MODULE__{} = csv, name_columns, detail_columns, headers? \\ true) do
    rows = if headers?, do: csv.rows, else: [csv.headers | csv.rows]

    for row <- rows,
        name = join(row, name_columns, " "),
        name != "",
        do: {name, join(row, detail_columns, " · ")}
  end

  defp join(row, columns, separator) do
    columns
    |> Enum.sort()
    |> Enum.map(&Enum.at(row, &1, ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(separator)
    |> String.split()
    |> Enum.join(" ")
  end
end
