module Reports
  class AdultIncontinenceReportService
    include ActionView::Helpers::NumberHelper
    attr_reader :year, :organization

    # @param year [Integer]
    # @param organization [Organization]
    def initialize(year:, organization:)
      @year = year
      @organization = organization
    end

    # @return [Hash]
    def report
      @report ||= { name: 'Adult Incontinence',
                    entries: {
                      'Adult incontinence supplies distributed' => number_with_delimiter(total_supplies_distributed),
                      'Adults Assisted Per Month' => adults_served_per_month.round,
                      'Adult incontinence supplies per adult per month' => supplies_per_adult_per_month.round,
                      'Adult incontinence supplies' => types_of_supplies,
                      '% adult incontinence supplies donated' => "#{percent_donated.round}%",
                      '% adult incontinence bought' => "#{percent_bought.round}%",
                      'Money spent purchasing adult incontinence supplies' => number_to_currency(money_spent_on_supplies)
                    } }
    end

    # @return [Integer]
    def distributed_loose_supplies
      @distributed_supplies ||= organization
                                .distributions
                                .for_year(year)
                                .joins(line_items: :item)
                                .merge(Item.adult_incontinence)
                                .sum('line_items.quantity')
    end

    # @return [Integer]
    def total_supplies_distributed
      distributed_loose_supplies + distributed_adult_incontinence_items_from_kits
    end

    def monthly_supplies
      total_supplies_distributed / 12.0
    end

    def supplies_per_adult_per_month
      monthly_supplies / (adults_served_per_month.nonzero? || 1)
    end

    def types_of_supplies
      organization.items.adult_incontinence.map(&:name).uniq.sort.join(', ')
    end

    # @return [Float]
    def percent_donated
      return 0.0 if total_supplies.zero?

      (donated_supplies / total_supplies.to_f) * 100
    end

    # @return [Float]
    def percent_bought
      return 0.0 if total_supplies.zero?

      (purchased_supplies / total_supplies.to_f) * 100
    end

    # @return [String]
    def money_spent_on_supplies
      organization.purchases.for_year(year).sum(:amount_spent_on_adult_incontinence_cents) / 100.0
    end

    ###### HELPER METHODS ######

    # @return [Integer]
    def purchased_supplies
      @purchased_supplies ||= LineItem.joins(:item)
                                      .merge(Item.adult_incontinence)
                                      .where(itemizable: organization.purchases.for_year(year))
                                      .sum(:quantity)
    end

    # @return [Integer]
    def total_supplies
      @total_supplies ||= purchased_supplies + donated_supplies
    end

    # @return [Integer]
    def donated_supplies
      @donated_supplies ||= LineItem.joins(:item)
                                    .merge(Item.adult_incontinence)
                                    .where(itemizable: organization.donations.for_year(year))
                                    .sum(:quantity)
    end

    def distributed_adult_incontinence_items_from_kits
      organization_id = @organization.id
      year = @year

      sql_query = <<-SQL
        SELECT SUM(line_items.quantity * kit_line_items.quantity)
        FROM distributions 
        INNER JOIN line_items ON line_items.itemizable_type = 'Distribution' AND line_items.itemizable_id = distributions.id 
        INNER JOIN items ON items.id = line_items.item_id 
        INNER JOIN kits ON kits.id = items.kit_id 
        INNER JOIN line_items AS kit_line_items ON kits.id = kit_line_items.itemizable_id
        INNER JOIN items AS kit_items ON kit_items.id = kit_line_items.item_id
        INNER JOIN base_items ON base_items.partner_key = kit_items.partner_key 
        WHERE distributions.organization_id = ?
          AND EXTRACT(year FROM issued_at) = ?
          AND LOWER(base_items.category) LIKE '%adult%'
          AND NOT (LOWER(base_items.category) LIKE '%wipes%' OR LOWER(base_items.name) LIKE '%wipes%')
          AND kit_line_items.itemizable_type = 'Kit';
      SQL

      sanitized_sql = ActiveRecord::Base.send(:sanitize_sql_array, [sql_query, organization_id, year])

      result = ActiveRecord::Base.connection.execute(sanitized_sql)

      result.first['sum'].to_i
    end

    def adults_served_per_month
      total_people_served_with_loose_supplies_per_month + total_distributed_kits_containing_adult_incontinence_items_per_month
    end

    def total_people_served_with_loose_supplies_per_month
      total_quantity = organization
                        .distributions
                        .for_year(year)
                        .joins(line_items: :item)
                        .merge(Item.adult_incontinence)
                        .sum('line_items.quantity / COALESCE(items.distribution_quantity, 50)')
      total_quantity.to_f / 12.0
    end

    def distributed_kits_for_year
      organization
        .distributions
        .for_year(year)
        .joins(line_items: { item: :kit })
        .distinct
        .pluck('kits.id')
    end

    def total_distributed_kits_containing_adult_incontinence_items_per_month
      kits = Kit.where(id: distributed_kits_for_year)
      adult_incontinence_kits = kits.select do |kit|
        kit.items.adult_incontinence.any?
      end
      adult_incontinence_kits.count.to_f / 12.0
    end
  end
end
