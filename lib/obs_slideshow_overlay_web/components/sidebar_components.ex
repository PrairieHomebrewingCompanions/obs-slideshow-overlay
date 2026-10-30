defmodule ObsSlideshowOverlayWeb.SidebarComponents do
  @moduledoc """
  The lists down the left of the Slideshows and Themes pages, with names
  that can be edited in place: the pencil (or a double-click) turns a name
  into a text box; Enter or clicking away saves, Esc cancels.

  The page handles `"rename_start"`, `"rename_save"` and `"rename_cancel"`,
  each with the item's `"id"` (`"item_id"` from the form); a save also has
  its `"name"` (or `"value"`, when it comes from leaving the box).
  """
  use Phoenix.Component

  import ObsSlideshowOverlayWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true, doc: "the DOM id"
  attr :item_id, :integer, required: true
  attr :name, :string, required: true
  attr :patch, :string, required: true
  attr :active, :boolean, default: false
  attr :editing, :boolean, default: false
  slot :badge

  def item(%{editing: true} = assigns) do
    ~H"""
    <li id={@id}>
      <form id={"#{@id}-rename"} phx-submit="rename_save" class="p-1 hover:bg-transparent">
        <input type="hidden" name="item_id" value={@item_id} />
        <input
          id={"#{@id}-name"}
          type="text"
          name="name"
          value={@name}
          required
          aria-label="Name"
          class="input input-sm w-full"
          phx-hook="SelectAll"
          phx-blur="rename_save"
          phx-value-id={@item_id}
          phx-keydown="rename_cancel"
          phx-key="Escape"
        />
      </form>
    </li>
    """
  end

  def item(assigns) do
    ~H"""
    <li id={@id} class="group relative">
      <.link
        id={"#{@id}-link"}
        patch={@patch}
        class={["pr-8", @active && "menu-active"]}
        phx-hook="RenameOnDoubleClick"
        data-id={@item_id}
      >
        <span class="truncate">{@name}</span>
        {render_slot(@badge)}
      </.link>
      <button
        type="button"
        class="btn btn-ghost btn-xs btn-square absolute top-1/2 right-1 -translate-y-1/2 opacity-0 group-hover:opacity-100 focus:opacity-100"
        phx-click="rename_start"
        phx-value-id={@item_id}
        aria-label={"Rename #{@name}"}
        title="Rename"
      >
        <.icon name="hero-pencil" class="size-3" />
      </button>
    </li>
    """
  end
end
