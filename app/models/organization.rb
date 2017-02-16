class Organization < ApplicationRecord
  has_many :locations
  has_many :import_organization_names
  has_many :import_organization_tags
  has_many :tags, through: :import_organization_tags

  has_paper_trail ignore: [:created_at, :updated_at]

  def import_organization_tags_for(tag)
    import_organization_tags.where(tag: tag)
  end

  def import_organization_names_for(name)
    import_organization_names.where(name: name)
  end
end