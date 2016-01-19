{.boundChecks: on.}

import macros
import strtabs
import strutils
import asyncdispatch
import asyncnet
import asynchttpserver
from net import BufferSize
import lists
import hashes as hashes
import tables
import strtabs
import marshal
import json
import base64
import cgi
import times
import os

import qt5_qtsql

import reflists
import microasynchttpserver
import qsqldatabase
import qvariant
import qtimezone
import qdatetime
import qsqlrecord
import influxql_to_sql
import influx_line_protocol_to_sql

type 
    DBQueryException = object of IOError
    URLParameterError = object of ValueError
    URLParameterNotFoundError = object of URLParameterError
    URLParameterInvalidError = object of URLParameterError

    JSONEntryValues = tuple
        order: OrderedTableRef[ref string, bool] not nil
        entries: SinglyLinkedRefList[Table[ref string, JSONField]] not nil

    SeriesAndData = tuple
        series: string
        data: JSONEntryValues

    # InfluxDB only supports four data types, which makes this easy
    # We add a fifth one so that we can properly support unsigned integers
    JSONFieldKind {.pure.} = enum
        Null,
        Integer,
        UInteger,
        Float,
        Boolean,
        String

    JSONField = object
        case kind: JSONFieldKind
        of JSONFieldKind.Null: discard
        of JSONFieldKind.Integer: intVal: int64
        of JSONFieldKind.UInteger: uintVal: uint64
        of JSONFieldKind.Float: floatVal: float64
        of JSONFieldKind.Boolean: booleanVal: bool
        of JSONFieldKind.String: stringVal: string

    QVariantType {.pure.} = enum
        Bool = 1
        Int = 2
        UInt = 3
        LongLong = 4
        ULongLong = 5
        Double = 6
        Char = 7
        String = 10
        Date = 14
        Time = 15
        DateTime = 16
        Long = 129
        Short = 130
        Char2 = 131
        ULong = 132
        UShort = 133
        UChar = 134
        Float = 135

    EpochFormat {.pure.} = enum
        RFC3339
        Hour
        Minute
        Second
        Millisecond
        Microsecond
        Nanosecond

const QUERY_HTTP_METHODS = "GET"
const WRITE_HTTP_METHODS = "POST"
const PING_HTTP_METHODS = "GET, HEAD"

const cacheControlZeroAge: string = "0"

when getEnv("cachecontrolmaxage") != "":
    const cachecontrolmaxage: string = getEnv("cachecontrolmaxage")
else:
    const cachecontrolmaxage: string = "0"

const cacheControlDontCacheHeader = "private, max-age=" & cacheControlZeroAge & ", s-maxage=" & cacheControlZeroAge & ", no-cache"
const cacheControlDoCacheHeader = "public, max-age=" & cachecontrolmaxage & ", s-maxage=" & cachecontrolmaxage

var corsAllowOrigin: cstring = nil

template JSON_CONTENT_TYPE_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "application/json", "Cache-Control", cacheControlDoCacheHeader, modeCaseSensitive)

template JSON_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "application/json", "Cache-Control", cacheControlDontCacheHeader, modeCaseSensitive)

template TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "text/plain", "Cache-Control", cacheControlDontCacheHeader, modeCaseSensitive)

template TEXT_CONTENT_TYPE_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "text/plain", "Cache-Control", cacheControlDoCacheHeader, modeCaseSensitive)

template PING_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "text/plain", "Cache-Control", cacheControlDontCacheHeader, "Date", date, "X-Influxdb-Version", "0.9.3-compatible-influxmysql", modeCaseSensitive)

var dbHostname: cstring = nil
var dbPort: cint = 0

template hash(x: ref string): Hash =
    hashes.hash(cast[pointer](x))

macro useDB(dbName: string, dbUsername: string, dbPassword: string, body: stmt): stmt {.immediate.} =
    # Create the try block that closes the database.
    var safeBodyClose = newNimNode(nnkTryStmt)
    safeBodyClose.add(body)

    ## Create the finally clause
    var safeBodyCloseFinally = newNimNode(nnkFinally)
    safeBodyCloseFinally.add(parseStmt("database.close"))
    
    ## Add the finally clause to the try block.
    safeBodyClose.add(safeBodyCloseFinally)

    # Create the try block that removes the database.
    var safeBodyRemove = newNimNode(nnkTryStmt)
    safeBodyRemove.add(
        newBlockStmt(
            newStmtList(
                newVarStmt(newIdentNode(!"database"), newCall(!"newQSqlDatabase", newStrLitNode("QMYSQL"), newIdentNode(!"qSqlDatabaseName"))),
                newCall(!"setHostName", newIdentNode(!"database"), newIdentNode(!"dbHostName")),
                newCall(!"setDatabaseName", newIdentNode(!"database"), dbName),
                newCall(!"setPort", newIdentNode(!"database"), newIdentNode(!"dbPort")),
                newCall(!"open", newIdentNode(!"database"), dbUsername, dbPassword),
                safeBodyClose
            )
        )
    )

    ## Create the finally clause.
    var safeBodyRemoveFinally = newNimNode(nnkFinally)
    safeBodyRemoveFinally.add(parseStmt("qSqlDatabaseRemoveDatabase(qSqlDatabaseName)"))

    ## Add the finally clause to the try block.
    safeBodyRemove.add(safeBodyRemoveFinally)

    # Put it all together.
    result = newBlockStmt(
                newStmtList(
                    parseStmt("""

var qSqlDatabaseStackId: uint8
var qSqlDatabaseName = "influx_mysql" & $cast[uint64](addr(qSqlDatabaseStackId))
                    """), 
                    safeBodyRemove
                )
            )

proc strdup(s: var string): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)

proc strdup(s: var cstring): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)

template useQuery(sql: cstring, query: var QSqlQueryObj) {.dirty.} =
    try:
        query.prepare(sql)
        query.exec
    except QSqlException:
        var exceptionMsg = cast[string](getCurrentExceptionMsg())
        var newExceptionMsg = exceptionMsg.strdup

        raise newException(DBQueryException, newExceptionMsg)

template useQuery(sql: cstring, database: var QSqlDatabaseObj) {.dirty.} =
    var query = database.qSqlQuery()
    sql.useQuery(query)

proc runDBQueryWithTransaction(sql: cstring, dbName: string, dbUsername: string, dbPassword: string) =
    useDB(dbName, dbUsername, dbPassword):
        block:
            "SET time_zone='UTC'".useQuery(database)

        database.beginTransaction
        sql.useQuery(database)
        database.commitTransaction

        # Workaround for weird compiler corner case
        database.close

proc getParams(request: Request): StringTableRef =
    result = newStringTable(modeCaseSensitive)

    for part in request.url.query.split('&'):
        let keyAndValue = part.split('=')

        if (keyAndValue.len == 2):
            result[keyAndValue[0]] = keyAndValue[1].decodeUrl

proc toRFC3339JSONField(dateTime: QDateTimeObj): JSONField =
    var timeStringConst = dateTime.toQStringObj("yyyy-MM-ddThh:mm:ss.zzz000000Z").toUtf8.constData.umc

    result.kind = JSONFieldKind.String
    result.stringVal = timeStringConst.strdup

proc toJSONField(msSinceEpoch: uint64, epoch: EpochFormat): JSONField =
    case epoch:
    of EpochFormat.RFC3339:
        var dateTime = newQDateTimeObj(qint64(msSinceEpoch))
        dateTime.setTimeZone(qTimeZoneUtc())

        result = dateTime.toRFC3339JSONField
    of EpochFormat.Hour:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch div 3600000
    of EpochFormat.Minute:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch div 60000
    of EpochFormat.Second:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch div 1000
    of EpochFormat.Millisecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch
    of EpochFormat.Microsecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch * 1000
    of EpochFormat.Nanosecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = msSinceEpoch * 1000000

proc toJSONField(record: QSqlRecordObj, i: cint, epoch: EpochFormat): JSONField =
    if not record.isNull(i):
        var valueVariant = record.value(i)

        case QVariantType(valueVariant.userType):
        of QVariantType.Date, QVariantType.Time, QVariantType.DateTime:
            var dateTime = valueVariant.toQDateTimeObj
            dateTime.setTimeZone(qTimeZoneUtc())

            case epoch:
            of EpochFormat.RFC3339:
                result = dateTime.toRFC3339JSONField
            else:
                result = uint64(dateTime.toMSecsSinceEpoch).toJSONField(epoch)

        of QVariantType.Bool:

            result.kind = JSONFieldKind.Boolean
            result.booleanVal = valueVariant
        
        of QVariantType.Int, QVariantType.LongLong, QVariantType.Char, QVariantType.Long,
            QVariantType.Short, QVariantType.Char2: 

            result.kind = JSONFieldKind.Integer
            result.intVal = valueVariant

        of QVariantType.UInt, QVariantType.ULongLong, QVariantType.ULong,
            QVariantType.UShort, QVariantType.UChar:

            result.kind = JSONFieldKind.UInteger
            result.uintVal = valueVariant

        of QVariantType.Double, QVariantType.Float:

            result.kind = JSONFieldKind.Float
            result.floatVal = valueVariant

        of QVariantType.String:

            var valueStringConst = valueVariant.toQStringObj.toUtf8.constData.umc

            result.kind = JSONFieldKind.String
            result.stringVal = valueStringConst.strdup

        else:

            raise newException(ValueError, "Cannot unpack QVariantObj of type \"" & $valueVariant.userType & "\"!")
    else:
        result.kind = JSONFieldKind.Null

proc addNulls(entries: SinglyLinkedRefList[Table[ref string, JSONField]] not nil, order: OrderedTableRef[ref string, bool] not nil,
                lastTime: uint64, newTime: uint64, period: uint64, epoch: EpochFormat, internedStrings: var Table[string, ref string]) =

    var lastTime = lastTime
    let timeInterned = internedStrings["time"]

    if ((newTime - lastTime) div period) > uint64(1):
        while true:
            lastTime += period

            if lastTime >= newTime:
                break

            var entryValues = newTable[ref string, JSONField]()
            for fieldName in order.keys:
                if fieldName != timeInterned:
                    entryValues[fieldName] = JSONField(kind: JSONFieldKind.Null)
                else:
                    entryValues[timeInterned] = lastTime.toJSONField(epoch)

            entries.append(entryValues)

proc runDBQueryAndUnpack(sql: cstring, series: string, period: uint64, fillNull: bool, epoch: EpochFormat, result: var DoublyLinkedList[SeriesAndData], internedStrings: var Table[string, ref string],
                         dbName: string, dbUsername: string, dbPassword: string)  =
    useDB(dbName, dbUsername, dbPassword):
        block:
            "SET time_zone='UTC'".useQuery(database)

        sql.useQuery(database)

        var entries = newSinglyLinkedRefList[Table[ref string, JSONField]]()
        var seriesAndData: SeriesAndData = (series: series, data: (order: cast[OrderedTableRef[ref string, bool] not nil](newOrderedTable[ref string, bool]()), 
                                entries: entries))
        result.append(seriesAndData)

        var order = seriesAndData.data.order

        var lastTime = uint64(0)
        var first = true

        while query.next() == true:
            var record = query.record
            let count = record.count - 1

            var entryValues = newTable[ref string, JSONField]()

            if fillNull:
                # For strict InfluxDB compatibility:
                #
                # InfluxDB will automatically return NULLs if there is no data for that GROUP BY timeframe block.
                # SQL databases do not do this, they return nothing if there is no data. So we need to add these
                # NULLs.
                var newTime = uint64(record.value("time").toMSecsSinceEpoch)

                if (period > uint64(0)) and not first:
                    entries.addNulls(order, lastTime, newTime, period, epoch, internedStrings)
                else:
                    first = false

                lastTime = newTime

            for i in countUp(0, count):
                var fieldNameConst = record.fieldName(i).toUtf8.constData.umc
                var fieldName: string = fieldNameConst.strdup

                # For strict InfluxDB compatibilty:
                #
                # We only return the name of the functions as the field, and not the name and the arguments.
                #
                # We also change "AVG" to "mean" since we change "mean" to "AVG" in the InfluxQL to SQL conversion.
                if fieldName[fieldName.len-1] == ')':
                    fieldName = fieldName.getToken('(', 0)

                    if fieldName == "AVG":
                        fieldName = "mean"

                var value = record.toJSONField(i, epoch)

                var fieldNameInterned = internedStrings.getOrDefault(fieldName)
                if fieldnameInterned == nil:
                    new(fieldNameInterned)
                    fieldNameInterned[] = fieldName

                    internedStrings[fieldName] = fieldNameInterned

                discard order.hasKeyOrPut(fieldNameInterned, true)
                entryValues[fieldNameInterned] = value

            entries.append(entryValues)

converter toJsonNode(field: JSONField): JsonNode =
    case field.kind:
    of JSONFieldKind.Null: result = newJNull()
    of JSONFieldKind.Integer: result = newJInt(BiggestInt(field.intVal))
    of JSONFieldKind.UInteger: result = newJInt(BiggestInt(field.uintVal))
    of JSONFieldKind.Float: result = newJFloat(field.floatVal)
    of JSONFieldKind.Boolean: result = newJBool(field.booleanVal)
    of JSONFieldKind.String: result = newJString(field.stringVal)

proc toJsonNode(kv: SeriesAndData): JsonNode =
    result = newJObject()
    var seriesArray = newJArray()
    var seriesObject = newJObject()

    seriesObject.add("name", newJString(kv.series))

    var columns = newJArray()

    for column in kv.data.order.keys:
        columns.add(newJString(column[]))

    seriesObject.add("columns", columns)

    var valuesArray = newJArray()

    for entry in kv.data.entries.items:
        var entryArray = newJArray()

        for column in kv.data.order.keys:
            entryArray.add(entry[column])

        valuesArray.add(entryArray)

    seriesObject.add("values", valuesArray)

    seriesArray.add(seriesObject)
    result.add("series", seriesArray)

proc toQueryResponse(ev: DoublyLinkedList[SeriesAndData]): string =
    var json = newJObject()
    var results = newJArray()

    for keyAndValue in ev.items:
        results.add(keyAndValue.toJsonNode)

    json.add("results", results)
    result = $json

proc withCorsIfNeeded(headers: StringTableRef, allowMethods: string, accessControlMaxAge: string): StringTableRef =
    if corsAllowOrigin != nil:
        if allowMethods != nil:
            headers["Access-Control-Allow-Methods"] = allowMethods

        if accessControlMaxAge != nil:
            headers["Access-Control-Max-Age"] = accessControlMaxAge

        headers["Access-Control-Allow-Origin"] = $corsAllowOrigin
        headers["Access-Control-Allow-Headers"] = "Accept, Origin, Authorization"
        headers["Access-Control-Allow-Credentials"] = "true"

    result = headers

proc withCorsIfNeeded(headers: StringTableRef, allowMethods: string): StringTableRef =
    if headers["Cache-Control"] == cacheControlDoCacheHeader:
        result = headers.withCorsIfNeeded(allowMethods, cachecontrolmaxage)
    elif headers["Cache-Control"] == cacheControlDontCacheHeader:
        result = headers.withCorsIfNeeded(allowMethods, cacheControlZeroAge)
    else:
        result = headers.withCorsIfNeeded(allowMethods, nil)

proc getOrHeadPing(request: Request) {.async.} =
    let date = getTime().getGMTime.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
    result = request.respond(Http204, "", PING_RESPONSE_HEADERS.withCorsIfNeeded(PING_HTTP_METHODS))

proc basicAuthToUrlParam(request: var Request) =
    if not request.headers.hasKey("Authorization"):
        return

    let parts = request.headers["Authorization"].split(' ')

    if (parts.len != 2) or (parts[0] != "Basic"):
        return

    let userNameAndPassword = base64.decode(parts[1]).split(':')

    if (userNameAndPassword.len != 2):
        return

    request.url.query.add("&u=")
    request.url.query.add(userNameAndPassword[0].encodeUrl)

    request.url.query.add("&p=")
    request.url.query.add(userNameAndPassword[1].encodeUrl)

proc getQuery(request: Request) {.async.} =
    GC_disable()
    defer: GC_enable()

    let params = getParams(request)

    let urlQuery = params["q"]
    let specifiedEpochFormat = params.getOrDefault("epoch")

    var epoch = EpochFormat.RFC3339

    if specifiedEpochFormat != "":
        case specifiedEpochFormat:
        of "h": epoch = EpochFormat.Hour
        of "m": epoch = EpochFormat.Minute
        of "s": epoch = EpochFormat.Second
        of "ms": epoch = EpochFormat.Millisecond
        of "u": epoch = EpochFormat.Microsecond
        of "ns": epoch = EpochFormat.Nanosecond
        else:
            raise newException(URLParameterInvalidError, "Invalid epoch parameter specified!")

    if urlQuery == nil:
        raise newException(URLParameterNotFoundError, "No \"q\" query parameter specified!")

    var internedStrings = initTable[string, ref string]()
    defer: internedStrings = initTable[string, ref string]()

    var entries = initDoublyLinkedList[tuple[series: string, data: JSONEntryValues]]()
    defer:
        # Explicitly hint the garbage collector that it can collect these.
        for entry in entries.items:
            entry.data.entries.removeAll

        entries = initDoublyLinkedList[tuple[series: string, data: JSONEntryValues]]()

    var dbName = ""
    var dbUsername = ""
    var dbPassword = ""

    if params.hasKey("db"):
        dbName = params["db"]

    if params.hasKey("u"):
        dbUsername = params["u"]

    if params.hasKey("p"):
        dbPassword = params["p"]

    var timeInterned: ref string
    defer: timeInterned = nil
    new(timeInterned)
    timeInterned[] = "time"

    internedStrings["time"] = timeInterned

    for line in urlQuery.splitLines:
        var series: string
        var period = uint64(0)
        var fillNull = false

        let sql = line.influxQlToSql(series, period, fillNull)
        
        when defined(logrequests):
            stdout.write("/query: ")
            stdout.write(line)
            stdout.write(" --> ")
            stdout.writeLine(sql)

        try:
            sql.runDBQueryAndUnpack(series, period, fillNull, epoch, entries, internedStrings, dbName, dbUsername, dbPassword)
        except DBQueryException:
            stdout.write("/query: ")
            stdout.write(line)
            stdout.write(" --> ")
            stdout.writeLine(sql)
            raise getCurrentException()

    result = request.respond(Http200, entries.toQueryResponse, JSON_CONTENT_TYPE_RESPONSE_HEADERS.withCorsIfNeeded(QUERY_HTTP_METHODS))

import posix

when defined(linux):
    import linux
else:
    const MSG_DONTWAIT = 0

proc postWrite(request: Request) {.async.} =
    GC_disable()
    defer: GC_enable()

    let params = getParams(request)

    var dbName = ""
    var dbUsername = ""
    var dbPassword = ""

    if params.hasKey("db"):
        dbName = params["db"]

    if params.hasKey("u"):
        dbUsername = params["u"]

    if params.hasKey("p"):
        dbPassword = params["p"]

    var internedStrings = initTable[string, ref string]()
    defer: internedStrings = initTable[string, ref string]()

    var entries = initTable[ref string, SQLEntryValues]()
    defer:
        # Explicitly hint the garbage collector that it can collect these.
        for entry in entries.values:
            entry.entries.removeAll

        entries = initTable[ref string, SQLEntryValues]()

    var sql = newStringOfCap(2097152)
    defer: sql = nil

    var readNow = newString(BufferSize)
    defer: readNow = nil

    var contentLength = 0
    
    if request.headers.hasKey("Content-Length"):
        contentLength = request.headers["Content-Length"].parseInt

    if contentLength == 0:
        result = request.respond(Http400, "Content-Length required, but not provided!", TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(WRITE_HTTP_METHODS))
        return

    var timeInterned: ref string
    defer: timeInterned = nil
    new(timeInterned)
    timeInterned[] = "time"

    internedStrings["time"] = timeInterned

    var lines = request.client.recvWholeBuffer
    defer: lines = nil

    var line = ""
    defer: line = nil

    var read = 0
    var noReadsStart: Time = Time(0)

    while read < contentLength:
        var chunkLen = contentLength - read
        if chunkLen > BufferSize:
            chunkLen = BufferSize

        request.client.rawRecv(readNow, chunkLen, MSG_DONTWAIT)
        if readNow.len < 1:
            if (errno != EAGAIN) and (errno != EWOULDBLOCK):
                raise newException(IOError, "Client socket disconnected!")
            else:
                if noReadsStart == Time(0):
                    noReadsStart = getTime()
                    continue
                else:
                    if (getTime() - noReadsStart) >= 2:
                        # Timeout, probably gave us the wrong Content-Length.
                        break
        else:
            noReadsStart = Time(0)

        read += readNow.len

        lines.add(readNow)

        var lineStart = 0
        while lineStart < lines.len:
            let lineEnd = lines.find("\n", lineStart) - "\n".len

            if lineEnd < 0 or lineEnd >= lines.len:
                break

            let lineNewSize = lineEnd - lineStart + 1
            line.setLen(lineNewSize)
            copyMem(addr(line[0]), addr(lines[lineStart]), lineNewSize)

            if line.len > 0:
                when defined(logrequests):
                    stdout.write("/write: ")
                    stdout.writeLine(line)

                line.lineProtocolToSQLEntryValues(entries, internedStrings)

            lineStart = lineEnd + "\n".len + 1

        if lineStart < lines.len:
            let linesNewSize = lines.len - lineStart
            
            moveMem(addr(lines[0]), addr(lines[lineStart]), linesNewSize)
            lines.setLen(linesNewSize)
        else:
            lines.setLen(0)

    for pair in entries.pairs:
        pair.sqlEntryValuesToSQL(sql)

        when defined(logrequests):
            stdout.write("/write: ")
            stdout.writeLine(sql)

        sql.runDBQueryWithTransaction(dbName, dbUsername, dbPassword)
        sql.setLen(0)

    result = request.respond(Http204, "", TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(WRITE_HTTP_METHODS))

template optionsCors(request: Request, allowMethods: string): Future[void] =
    request.respond(Http200, "", TEXT_CONTENT_TYPE_RESPONSE_HEADERS.withCorsIfNeeded(allowMethods))

proc router(request: Request) {.async.} =
    var request = request

    try:
        request.basicAuthToUrlParam

        when defined(logrequests):
            stdout.write(request.url.path)
            stdout.write('?')
            stdout.writeLine(request.url.query)

        if (request.reqMethod == "get") and (request.url.path == "/query"):
            asyncCheck request.getQuery
            return
        elif (request.reqMethod == "post") and (request.url.path == "/write"):
            asyncCheck request.postWrite
            return
        elif ((request.reqMethod == "get") or (request.reqMethod == "head")) and (request.url.path == "/ping"):
            asyncCheck request.getOrHeadPing
            return
        elif (request.reqMethod == "options") and (corsAllowOrigin != nil):
            case request.url.path:
            of "/query":
                asyncCheck request.optionsCors(QUERY_HTTP_METHODS)
                return
            of "/write":
                asyncCheck request.optionsCors(WRITE_HTTP_METHODS)
                return
            of "/ping":
                asyncCheck request.optionsCors(PING_HTTP_METHODS)
                return
            else:
                discard

        # Fall through on purpose, we didn't have a matching route.
        let responseMessage = "Route not found for [reqMethod=" & request.reqMethod & ", url=" & request.url.path & "]"
        stdout.writeLine(responseMessage)

        asyncCheck request.respond(Http400, responseMessage, TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(request.reqMethod.toUpper))
    except IOError, ValueError:
        let e = getCurrentException()
        stderr.write(e.getStackTrace())
        stderr.write("Error: unhandled exception: ")
        stderr.writeLine(getCurrentExceptionMsg())

        var errorResponseHeaders = JSON_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS

        if request.reqMethod != nil:
            errorResponseHeaders = errorResponseHeaders.withCorsIfNeeded(request.reqMethod.toUpper)
        else:
            errorResponseHeaders = errorResponseHeaders.withCorsIfNeeded(nil)

        result = request.respond(Http400, $( %*{ "error": getCurrentExceptionMsg() } ), errorResponseHeaders)

proc quitUsage() =
    stderr.writeLine("Usage: influx_mysql <mysql address:mysql port> <influxdb address:influxdb port> [cors allowed origin]")
    quit(QuitFailure)

block:
    var dbHostnameString = "localhost"
    dbPort = 3306

    var httpServerHostname = ""
    var httpServerPort = 8086

    let params = paramCount()

    if (params < 2) or (params > 3):
        if (params < 2):
            stderr.writeLine("Error: Not enough arguments specified!")
        else:
            stderr.writeLine("Error: Too many arguments specified!")

        quitUsage()

    let dbConnectionInfo = paramStr(1).split(':')
    let httpServerInfo = paramStr(2).split(':')

    case dbConnectionInfo.len:
    of 0:
        discard
    of 1:
        dbHostnameString = dbConnectionInfo[0]
    of 2:
        dbHostnameString = dbConnectionInfo[0]

        try:
            dbPort = cint(dbConnectionInfo[1].parseInt)
        except ValueError:
            stderr.writeLine("Error: Invalid mysql port specified!")
            quitUsage()
    else:
        stderr.writeLine("Error: Invalid mysql address, mysql port combination specified!")
        quitUsage()

    case httpServerInfo.len:
    of 0:
        discard
    of 1:
        httpServerHostname = httpServerInfo[0]
    of 2:
        httpServerHostname = httpServerInfo[0]

        try:
            httpServerPort = httpServerInfo[1].parseInt
        except ValueError:
            stderr.writeLine("Error: Invalid influxdb port specified!")
            quitUsage()
    else:
        stderr.writeLine("Error: Invalid influxdb address, influxdb port combination specified!")
        quitUsage()

    dbHostname = cast[cstring](allocShared0(dbHostnameString.len + 1))
    copyMem(addr(dbHostname[0]), addr(dbHostnameString[0]), dbHostnameString.len)

    if params == 3:
        var corsAllowOriginString = paramStr(3)

        corsAllowOrigin = cast[cstring](allocShared0(corsAllowOriginString.len + 1))
        copyMem(addr(corsAllowOrigin[0]), addr(corsAllowOriginString[0]), corsAllowOriginString.len)

    defer:
        deallocShared(dbHostname)

        if (corsAllowOrigin != nil):
            deallocShared(corsAllowOrigin)

    try:
        waitFor newMicroAsyncHttpServer().serve(Port(httpServerPort), router, httpServerHostname)
    except Exception:
        let e = getCurrentException()
        stderr.write(e.getStackTrace())
        stderr.write("Error: unhandled exception: ")
        stderr.writeLine(getCurrentExceptionMsg())

        quit(QuitFailure)
