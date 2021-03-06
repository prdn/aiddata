@include = ->

  _ = require 'underscore'
  fs = require 'fs'
  d3 = require 'd3'
  csv = require 'csv'
  queue = require 'queue-async'

  dv = require './dv-table'
  utils = require './data-utils'
  pu = require '../data/purposes'
  aidutils = require './frontend/utils-aiddata'
  caching = require './caching-loader'

  cachedFlowsFile = if @app.settings.env is "development"
    "flows-sample.csv"
  else
    "flows.csv"


  
  # used to validate the user input in commitments queries
  aiddataNodeNames = {}
  csv()
    .fromPath(__dirname + '/../data/static/data/aiddata-nodes.csv')
    .on('data', (row, index) ->
      aiddataNodeNames[row[0]] = row[1]
    )



  getFlows = caching.loader { preload : true }, (callback) ->

    columns = 
      date : "ordinal"
      donor : "nominal"
      recipient : "nominal"
      sum_amount_usd_constant : "numeric"
      purpose : "nominal"


    dv.loadFromCsv "../data/static/data/#{cachedFlowsFile}", columns, callback




  getPurposeTree = caching.loader { preload : true }, (callback) ->

    queue()
      .defer((cb) ->
        fs.readFile 'data/static/data/purposes.json', (err, result) ->
          result = JSON.parse(result) unless err?
          console.log "Purposes file loaded"
          cb(err, result)
      )
      .await (err, results) =>
        if err? then callback(err)
        else
          [ purposes ] = results

          callback(null, purposes)






  @get '/dv/flows/breaknsplit.csv': ->
    getFlows (err, table) => 
      if err? then @next err
      else

        agg = table.aggregate()
          .sparse()
          .sum("sum_amount_usd_constant")
          .count()



        # if @query.breakby
        #   breakby = @query.breakby.split(",")
          
        #   for b in breakby
        #     unless b in ["date", "donor", "recipient", "purpose"]
        #       @send { err: "Bad breakby" }
        #       return
        #     breakby.push b

        #   agg.by.apply(this, breakby)


        # if @query.purpose?
        #   purpose = @query.purpose
        #   if (purpose? and not /^[0-9]{1,5}$/.test purpose)
        #     @send { err: "Bad purpose" }
        #     return

        # #console.log @query.donor
        # if @query.donor? or @query.recipient?
        #   [donor, recipient] = [@query.donor, @query.recipient]

        #   re = /^[A-Za-z\-0-9\(\)]{2,10}$/
        #   if (donor? and not re.test donor) or (recipient and not re.test recipient)
        #     @send { err: "Bad donor/recipient" }
        #     return

        # if donor? or recipient? or purpose?
        #   agg.where((get) -> 
        #     (not(donor) or get("donor") is donor) and 
        #     (not(recipient) or get("recipient") is recipient) and
        #     (not(purpose) or get("purpose").indexOf(purpose) == 0)
        #   )

        plusYears = (date, numYears) ->
          d = new Date(date.getTime()); d.setFullYear(d.getFullYear() + numYears); d

        # used to sanity-filter the input data
        minDate = plusYears(new Date(), -100).getFullYear()
        maxDate = plusYears(new Date(), +5).getFullYear()

        agg.by.apply(this, @query.breakby?.split(","))

        filter = (if @query.filter? then JSON.parse(@query.filter) else null)
        
        if filter?.purpose?
          filter.purpose = filter.purpose.map (v) ->
            if /^[0-9]*\*[0-9]*$/.test(v)
              re = "^"+v.replace("*", ".*")
              console.log re
              new RegExp(re)
            else
              v

        findMatch = (values, propVal) ->                
          found = false
          for v in values
            if v instanceof RegExp
              if v.test(propVal)
                found = true
                break
            else
              if (propVal is v)
                found = true
                break
          found



        agg.where((get) ->

          return false unless (minDate <= +get("date") <= maxDate)

          if filter?
            for prop, values of filter

              found = (
                if prop is "node"
                  (findMatch(values, get("donor")) or findMatch(values, get("recipient")))
                else
                  findMatch(values, get(prop))
              )


              return false unless found

          return true
        )

        data = agg.columns()

        anykey = d3.keys(data)[0]
        anycolumn = data[anykey]

        if @query.download?
          exportFilename = "aiddata-export.csv"
          @response.setHeader('Content-Type: text/csv; name="'+exportFilename+'";')
          @response.setHeader('Content-Disposition: attachment; filename="'+exportFilename+'";')

        @response.write "#{col for col of data}\n"
        csv()
          .from(anycolumn)
          .toStream(@response)
          .transform (d, i) -> vals[i] for col,vals of data








  @get '/dv/flows/by/od.csv': ->
    getFlows (err, table) => 
      if err? then @next err
      else
        agg = table.aggregate()
          .sparse()
          .by("date", "donor", "recipient")
          .sum("sum_amount_usd_constant")
          .count()

        if @query.purpose?
          purpose = @query.purpose

          re = /^[0-9]{1,5}$/
          if (purpose? and not re.test purpose)
            @send { err: "Bad purpose" }
            return

          agg.where((get) -> get("purpose").indexOf(purpose) == 0)

        data = agg.columns()

        @response.write "#{col for col of data}\n"
        csv()
          .from(data.date)
          .toStream(@response)
          .transform (d, i) -> vals[i] for col,vals of data








  @get '/dv/flows/by/purpose.csv': -> 

    getFlows (err, table) =>
      if err? then @next err
      else
        agg = table.aggregate().sparse()
          .by("date", "purpose")
          .sum("sum_amount_usd_constant")
          .as("sum_amount_usd_constant", "sum")
          .as("purpose", "code")
          .count()

        if @query.origin? or @query.dest?
          [origin, dest] = [@query.origin, @query.dest]

          re = /^[A-Za-z\-0-9\,\.\s\(\)]{2,64}$/
          if (origin? and not re.test origin) or (dest and not re.test dest)
            @send { err: "Bad origin/dest" }
            return
              
          agg.where((get) -> 
            (not(origin) or get("donor") is origin) and (not(dest) or get("recipient") is dest)
          )


        data = agg.columns()

        @response.write "#{col for col of data}\n"
        csv()
          .from(data.date)
          .toStream(@response)
          .transform (d, i) -> vals[i] for col,vals of data
      










  @get '/purposes.json': -> 
    getPurposeTree (err, data) =>
      if err? then @next(err)
      else
        @send data
          
  
  # input: { col1:["a", "b"], col2:["A", "B"], ... } 
  # output: [ {col1:"a", col2:"b"}, {col1:"A", col2:"B"}, ... ]
  columnsAsRows = do ->
    anyProp = (obj) -> return prop for prop of obj
    (data) ->
      anyColumn = anyProp(data)
      length = data[anyColumn].length
      rows = []
      for i in [0..length-1]
        row = {}
        row[f] = data[f][i] for f of data
        rows.push row
      rows




  #getFlowTotalsByPurposeAndDate = caching.loader { preload : true }, (callback) ->

  getFlowTotalsByPurposeAndDate = (origin, dest, node) ->
    (callback) ->
      getFlows (err, table) -> 
        if err? then callback err
        else
          agg = table.aggregate().sparse()
            .by("date", "purpose")
            .sum("sum_amount_usd_constant")
            .as("sum_amount_usd_constant", "sum")
            .as("purpose", "code")
            .count()

          if origin? or dest? or node?
            agg.where((get) -> 
              (not(origin) or (get("donor") is origin)) and 
              (not(dest) or (get("recipient") is dest)) and
              (not(node) or (get("donor") is node)  or (get("recipient") is node)) 
            )

          data = agg.columns()

          rows = columnsAsRows(data)

          nested = d3.nest()
            .key((d) -> d.code)
            .key((d) -> d.date)
            .rollup((arr) ->
              for d in arr
                delete d.code; delete d.date
                #d.sum = ~~(d.sum / 1000)
              if arr.length is 1 then arr[0] else arr
            )
            .map(rows)

          callback null, nested




  @get '/purposes-with-totals.json': ->

    # 'node' means we need flows of a specific node, both incoming and outgoing
    if @query.origin? or @query.dest? or @query.node
      [ origin, dest, node ] = [ @query.origin, @query.dest, @query.node ]

      re = /^.{2,64}$/
      if (origin? and not re.test origin) or (dest and not re.test dest) or (node and not re.test node)
        @send { err: "Bad origin/dest/node" }
        return


    queue()
      .defer(getPurposeTree)
      .defer(getFlowTotalsByPurposeAndDate(origin, dest, node))
      .await (err, results) =>

        if err? then @next(err)
        else
          [ purposeTree, flowsByPurpose ] = results


          # provide the leaves (not the parent nodes!) with totals

          recurse = (tree) ->
            unless tree.values?
              # leaf nodes
              t =   
                key : tree.key
                name : tree.name
                #totals : flowsByPurpose[tree.code]

              # flatten sum and count attrs to simplify "provideWithTotals"
              for date, vals of flowsByPurpose[tree.key]
                for name, v of vals
                  t["#{name}_#{date}"] = v

            else
              t =
                key : tree.key  #+ "*"
                name : tree.name
                values : (recurse(n) for n in tree.values)

            t

          # the tree is deeply cloned 
          # so that the tree in the cache stays intact


          @send recurse(purposeTree)









