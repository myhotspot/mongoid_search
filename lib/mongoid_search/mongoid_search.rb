module Mongoid::Search
  extend ActiveSupport::Concern

  included do
    cattr_accessor :search_fields, :match, :allow_empty_search, :relevant_search, :stem_keywords, :ignore_list
    self.match = {}
    self.allow_empty_search = {}
    self.relevant_search = {}
    self.stem_keywords = {}
    self.ignore_list = {}
    self.search_fields = {}   
    field :_keywords, :default => {}
    index :_keywords
    before_save :set_keywords
  end

  module ClassMethods #:nodoc:
    # Set a field or a number of fields as sources for search
    def search_in(namespace, *args)
            
      options = args.last.is_a?(Hash) && [:match, :allow_empty_search, :relevant_search, :stem_keywords, :ignore_list].include?(args.last.keys.first) ? args.pop : {}
      raise "Namespace not found" if namespace.empty?
      self.match[namespace]              = [:any, :all].include?(options[:match]) ? options[:match] : :any
      self.allow_empty_search[namespace] = [true, false].include?(options[:allow_empty_search]) ? options[:allow_empty_search] : false
      self.relevant_search[namespace]    = [true, false].include?(options[:relevant_search]) ? options[:allow_empty_search] : false
      self.stem_keywords[namespace]      = [true, false].include?(options[:stem_keywords]) ? options[:allow_empty_search] : false
      self.ignore_list[namespace]        = YAML.load(File.open(options[:ignore_list]))["ignorelist"] if options[:ignore_list].present?      
      self.search_fields[namespace]      = (self.search_fields[namespace] || []).concat args
    end

    def search(namespace, query, options={})
      if relevant_search[namespace]
        search_relevant(namespace, query, options)
      else
        search_without_relevance(namespace, query, options)
      end
    end
    
    # Mongoid 2.0.0 introduces Criteria.seach so we need to provide
    # alternate method
    alias csearch search

    def search_without_relevance(namespace, query, options={})
      raise "Namespace not found" unless namespace
      return criteria.all if query.blank? && allow_empty_search[namespace]
      namespace_string = "_keywords." + namespace.inspect
      namespace_string[10] = ""
      criteria.send("#{(options[:match]||self.match[namespace]).to_s}_in", namespace_string => Util.keywords(query, stem_keywords[namespace], ignore_list[namespace]).map { |q| /#{q}/ })
    end
    
    # I know what this method should do, but I don't really know what it does.
    # It was a pull from another fork, with no tests on it. Proably should be rewrited (and tested).
    def search_relevant(namespace, query, options={})
      raise "Namespace not found" unless namespace
      return criteria.all if query.blank? && self.allow_empty_search[namespace]
           
      keywords = Util.keywords(query, stem_keywords[namespace], ignore_list[namespace])
    
      map = <<-EOS
        function() {
          var entries = 0
          for(i in keywords)
              for(j in this._keywords[namespace]) {
                if(this._keywords[namespace][j] == keywords[i])
                  entries++
            }
          if(entries > 0)
            emit(this._id, entries)
        }
      EOS
      reduce = <<-EOS
        function(key, values) {
          return(values[0])
        }
      EOS

      #raise [self.class, self.inspect].inspect
        
      
      
      kw_conditions = keywords.map do |kw|
        {:_keywords => kw}
      end

      criteria = (criteria || self).any_of(*kw_conditions)

      query = criteria.selector

      options.delete(:limit)
      options.delete(:skip)
      options.merge! :scope => {:keywords => keywords, :namespace => namespace}, :query => query

      # res = collection.map_reduce(map, reduce, options)
      # res.find.sort(['value', -1]) # Cursor
      
      puts options.inspect
      
      collection.map_reduce(map, reduce, options)
    end
  end

  private

  # TODO: This need some refactoring..
  def set_keywords
    self.search_fields.keys.each do |namespace|      
      self._keywords[namespace] = self.search_fields[namespace].map do |field|
        if field.is_a?(Hash)              
          field.keys.map do |key|
            attribute = self.send(key)
            method = field[key]   
            attribute = [attribute] if !attribute.is_a?(Array)                                
            method = [method]  if !method.is_a?(Array)
            method.map {|m| attribute.map { |a| Util.keywords a.send(m), stem_keywords[namespace], ignore_list[namespace] } }
          end
        else          
          value = self[field]
          value = [value] if !value.is_a?(Array)
          value.map {|v| Util.keywords(v, stem_keywords[namespace], ignore_list[namespace]) if v}
        end
      end.flatten.map(&:to_s).select{|f| not f.empty? }.uniq.sort
      
    end
  end
end
