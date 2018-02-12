module TopNRecords
  def self.parse_order(klass, order)
    case order
    when Hash
      unless order.size == 1 && %i[asc desc].include?(order.first.last)
        raise ArgumentError, 'invalid order'
      end
      order.first
    when Symbol
      [order, :asc]
    when NilClass
      [klass.primary_key, :asc]
    else
      raise ArgumentError, 'invalid order'
    end
  end

  def self.load(klass, column, keys, limit:, order: nil, condition: nil)
    order_key, order_mode = parse_order klass, order
    records = klass.find_by_sql(
      TopNRecords::SQLBuilder.top_n_sql(
        table_name: klass.table_name,
        group_column: column,
        group_keys: keys,
        limit: limit,
        order_mode: order_mode,
        order_key: order_key,
        condition: condition
      )
    )
    result = Hash.new { [] }.merge(records.group_by { |o| o[column] })
    order_sub_key = klass.primary_key
    result.transform_values do |grouped_records|
      existings, blanks = grouped_records.partition { |o| o[order_key] }
      existings.sort_by! { |o| [o[order_key], o[order_sub_key]] }
      blanks.sort_by! { |o| o[order_sub_key] }
      ordered = existings + blanks
      ordered.reverse! if order_mode == :desc
      ordered.take limit
    end
  end

  module SQLBuilder
    def self.top_n_sql(table_name:, group_column:, group_keys:, condition:, limit:, order_mode:, order_key:)
      order_op = order_mode == :asc ? :< : :>
      condition_sql = where_condition_to_sql condition
      group_key_table = value_table(:X, :group_key, group_keys)
      %(
        SELECT "#{table_name}".*
        FROM (
          SELECT *,
          (
            SELECT "#{table_name}"."#{order_key}" FROM "#{table_name}"
            WHERE "#{table_name}"."#{group_column}" = X.group_key
            #{"AND #{condition_sql}" if condition_sql}
            ORDER BY "#{table_name}"."#{order_key}" #{order_mode.to_s.upcase}
            LIMIT 1 OFFSET #{limit.to_i}
          ) AS last_value
          FROM #{group_key_table}
        ) T
        INNER JOIN "#{table_name}" ON
          "#{table_name}"."#{group_column}" = T.group_key
          AND (
            T.last_value IS NULL
            OR "#{table_name}"."#{order_key}" #{order_op} T.last_value
          )
        #{"WHERE #{condition_sql}" if condition_sql}
      )
    end

    def self.value_table(table, column, values)
      if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        values_value_table(table, column, values)
      else
        union_value_table(table, column, values)
      end
    end

    def self.union_value_table(table, column, values)
      sanitize_sql_array [
        "(SELECT 1 AS #{column}#{' UNION SELECT ?' * values.size}) AS #{table}",
        *values
      ]
    end

    def self.values_value_table(table, column, values)
      sanitize_sql_array [
        "(VALUES #{(['(?)'] * values.size).join(',')}) AS #{table} (#{column})",
        *values
      ]
    end

    def self.where_condition_to_sql(condition)
      case condition
      when String
        condition
      when Array
        sanitize_sql_array condition
      when Hash
        condition.map { |k, v| kv_condition_to_sql k, v }.join ' AND '
      end
    end

    def self.kv_condition_to_sql(key, value)
      sql_binds = begin
        case value
        when NilClass
          %("#{key}" IS NULL)
        when Range
          if value.exclude_end?
            [%("#{key}" >= ? AND "#{key} < ?), value.begin, value.end]
          else
            [%("#{key}" BETWEEN ? AND ?), value.begin, value.end]
          end
        when Enumerable
          [%("#{key}" IN (?)), value.to_a]
        else
          [%("#{key}" IS ?), value]
        end
      end
      sanitize_sql_array sql_binds
    end

    def self.sanitize_sql_array(array)
      ActiveRecord::Base.send :sanitize_sql_array, array
    end
  end
end

TopNRecords.load(Comment, :post_id, [1, 2, 3], limit: 2, order: { created_at: :desc }, condition: {id: (1..32)})
__END__
{1=>
  [#<Comment:0x00007fa98763bd88 id: 19, post_id: 1 ... >,
   #<Comment:0x00007fa9876400b8 id: 11, post_id: 1 ... >],
 3=>
  [#<Comment:0x00007fa98763b720 id: 31, post_id: 3 ... >,
   #<Comment:0x00007fa98763ba68 id: 25, post_id: 3 ... >]}
