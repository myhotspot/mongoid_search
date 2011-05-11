class Variant < Product
  field :color
  search_in :default, :color
end