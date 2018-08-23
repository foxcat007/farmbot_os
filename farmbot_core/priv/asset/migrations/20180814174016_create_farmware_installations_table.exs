defmodule Farmbot.Asset.Repo.Migrations.CreateFarmwareInstallationsTable do
  use Ecto.Migration

  def change do
    create table("farmware_installations", primary_key: false) do
      add(:id, :integer)
      add(:url, :string)
      add(:first_party, :boolean)
    end

    create(unique_index("farmware_installations", [:id, :url]))
  end
end