/*
 * Windows Update error codes, grouped by component.
 * Codes and symbolic names follow Microsoft's reference:
 *   https://learn.microsoft.com/en-us/windows/deployment/update/windows-update-error-reference
 * Descriptions are short paraphrases. Each code is mapped to one or more fix playbooks
 * (see PLAYBOOKS in generator.js). "info" means no device-side fix is expected.
 *
 * Row format: [code, symbolicName, shortDescription, playbooks]
 */
(function (root) {
  'use strict';

  const SOURCE_URL = 'https://learn.microsoft.com/en-us/windows/deployment/update/windows-update-error-reference';

  const COMPONENTS = [
    { id: 'au', name: 'Automatic Updates', rows: [
      ['0x8024A000', 'WU_E_AU_NOSERVICE', 'Automatic Updates could not service incoming requests.', ['services']],
      ['0x8024A002', 'WU_E_AU_NONLEGACYSERVER', 'Old Automatic Updates client stopped because the WSUS server was upgraded.', ['policy']],
      ['0x8024A003', 'WU_E_AU_LEGACYCLIENTDISABLED', 'The old Automatic Updates client was disabled.', ['policy', 'services']],
      ['0x8024A004', 'WU_E_AU_PAUSED', 'Automatic Updates was paused and could not process requests.', ['services']],
      ['0x8024A005', 'WU_E_AU_NO_REGISTERED_SERVICE', 'No unmanaged update service is registered with Automatic Updates.', ['services', 'reset']],
      ['0x8024AFFF', 'WU_E_AU_UNEXPECTED', 'Automatic Updates error not covered by a more specific code.', ['services', 'reset']]
    ]},
    { id: 'ui', name: 'Windows Update UI', rows: [
      ['0x80243001', 'WU_E_INSTALLATION_RESULTS_UNKNOWN_VERSION', 'Install results in the registry use an unrecognised format version.', ['reset']],
      ['0x80243002', 'WU_E_INSTALLATION_RESULTS_INVALID_DATA', 'Install results in the registry are in an invalid format.', ['reset']],
      ['0x80243003', 'WU_E_INSTALLATION_RESULTS_NOT_FOUND', 'Install results are missing; the operation may not have started.', ['reset']],
      ['0x80243004', 'WU_E_TRAYICON_FAILURE', 'Could not create the notification-area icon.', ['info']],
      ['0x80243FFD', 'WU_E_NON_UI_MODE', 'UI cannot be shown in non-UI mode; UI modules may be missing.', ['info']],
      ['0x80243FFE', 'WU_E_WUCLTUI_UNSUPPORTED_VERSION', 'Unsupported version of the Windows Update client UI exports.', ['repair']],
      ['0x80243FFF', 'WU_E_AUCLIENT_UNEXPECTED', 'Client UI error not covered by a more specific code.', ['services', 'reset']],
      ['0x8024043D', 'WU_E_SERVICEPROP_NOTAVAIL', 'A requested service property is unavailable.', ['services']]
    ]},
    { id: 'inventory', name: 'Inventory', rows: [
      ['0x80249001', 'WU_E_INVENTORY_PARSEFAILED', 'The inventory rule file could not be parsed.', ['reset']],
      ['0x80249002', 'WU_E_INVENTORY_GET_INVENTORY_TYPE_FAILED', 'Could not get the requested inventory type from the server.', ['network', 'reset']],
      ['0x80249003', 'WU_E_INVENTORY_RESULT_UPLOAD_FAILED', 'Inventory results could not be uploaded to the server.', ['network']],
      ['0x80249004', 'WU_E_INVENTORY_UNEXPECTED', 'Inventory error not covered by a more specific code.', ['reset']],
      ['0x80249005', 'WU_E_INVENTORY_WMI_ERROR', 'A WMI error occurred while enumerating class instances.', ['repair']]
    ]},
    { id: 'ee', name: 'Expression evaluator', rows: [
      ['0x8024E001', 'WU_E_EE_UNKNOWN_EXPRESSION', 'An applicability expression was not recognised.', ['reset']],
      ['0x8024E002', 'WU_E_EE_INVALID_EXPRESSION', 'An applicability expression was invalid.', ['reset']],
      ['0x8024E003', 'WU_E_EE_MISSING_METADATA', 'An expression has the wrong number of metadata nodes.', ['reset']],
      ['0x8024E004', 'WU_E_EE_INVALID_VERSION', 'Serialized expression data has an invalid version.', ['reset']],
      ['0x8024E005', 'WU_E_EE_NOT_INITIALIZED', 'The expression evaluator could not initialise.', ['reset', 'repair']],
      ['0x8024E006', 'WU_E_EE_INVALID_ATTRIBUTEDATA', 'An expression contained an invalid attribute.', ['reset']],
      ['0x8024E007', 'WU_E_EE_CLUSTER_ERROR', 'The cluster state of the computer could not be determined.', ['info']],
      ['0x8024EFFF', 'WU_E_EE_UNEXPECTED', 'Expression evaluator error not covered by a more specific code.', ['reset']]
    ]},
    { id: 'reporter', name: 'Reporter', rows: [
      ['0x80247001', 'WU_E_OL_INVALID_SCANFILE', 'The offline scan package was invalid.', ['reset']],
      ['0x80247002', 'WU_E_OL_NEWCLIENT_REQUIRED', 'The scan package needs a newer Windows Update Agent.', ['repair']],
      ['0x80247FFF', 'WU_E_OL_UNEXPECTED', 'Search using the scan package failed.', ['reset']],
      ['0x8024F001', 'WU_E_REPORTER_EVENTCACHECORRUPT', 'The reporting event cache file is corrupt.', ['reset']],
      ['0x8024F002', 'WU_E_REPORTER_EVENTNAMESPACEPARSEFAILED', 'The event namespace descriptor XML could not be parsed.', ['reset']],
      ['0x8024F003', 'WU_E_INVALID_EVENT', 'An event was invalid (descriptor XML could not be parsed).', ['reset']],
      ['0x8024F004', 'WU_E_SERVER_BUSY', 'The server rejected an event because it was too busy.', ['network']],
      ['0x8024FFFF', 'WU_E_REPORTER_UNEXPECTED', 'Reporter error not covered by a more specific code.', ['reset']]
    ]},
    { id: 'redirector', name: 'Redirector', rows: [
      ['0x80245001', 'WU_E_REDIRECTOR_LOAD_XML', 'The redirector XML (wuredir.cab) could not be loaded.', ['reset', 'network']],
      ['0x80245002', 'WU_E_REDIRECTOR_S_FALSE', 'The redirector XML is missing required information.', ['reset', 'network']],
      ['0x80245003', 'WU_E_REDIRECTOR_ID_SMALLER', 'Downloaded redirector cab is older than the cached one.', ['reset']],
      ['0x80245FFF', 'WU_E_REDIRECTOR_UNEXPECTED', 'Redirector error not covered by a more specific code.', ['reset', 'network']]
    ]},
    { id: 'pt-soap', name: 'Protocol Talker (SOAP client)', rows: [
      ['0x80244000', 'WU_E_PT_SOAPCLIENT_BASE', 'Base value for SOAP client errors.', ['reset', 'network']],
      ['0x80244001', 'WU_E_PT_SOAPCLIENT_INITIALIZE', 'SOAP client failed to initialise, possibly an MSXML problem.', ['repair']],
      ['0x80244002', 'WU_E_PT_SOAPCLIENT_OUTOFMEMORY', 'SOAP client ran out of memory.', ['reboot']],
      ['0x80244003', 'WU_E_PT_SOAPCLIENT_GENERATE', 'SOAP client failed to build the request.', ['reset']],
      ['0x80244004', 'WU_E_PT_SOAPCLIENT_CONNECT', 'SOAP client could not connect to the update server.', ['network']],
      ['0x80244005', 'WU_E_PT_SOAPCLIENT_SEND', 'SOAP client failed to send a message (WinHTTP error).', ['network']],
      ['0x80244006', 'WU_E_PT_SOAPCLIENT_SERVER', 'SOAP client failed because of a server error.', ['network']],
      ['0x80244007', 'WU_E_PT_SOAPCLIENT_SOAPFAULT', 'SOAP client received a SOAP fault.', ['reset', 'network']],
      ['0x80244008', 'WU_E_PT_SOAPCLIENT_PARSEFAULT', 'SOAP client could not parse a SOAP fault.', ['reset']],
      ['0x80244009', 'WU_E_PT_SOAPCLIENT_READ', 'SOAP client failed while reading the server response.', ['network']],
      ['0x8024400A', 'WU_E_PT_SOAPCLIENT_PARSE', 'SOAP client could not parse the server response.', ['reset', 'network']]
    ]},
    { id: 'pt', name: 'Protocol Talker (other)', rows: [
      ['0x8024400B', 'WU_E_PT_SOAP_VERSION', 'Unrecognised namespace in the SOAP envelope.', ['reset']],
      ['0x8024400C', 'WU_E_PT_SOAP_MUST_UNDERSTAND', 'SOAP client could not understand a header.', ['reset']],
      ['0x8024400D', 'WU_E_PT_SOAP_CLIENT', 'The SOAP message was malformed.', ['reset', 'policy']],
      ['0x8024400E', 'WU_E_PT_SOAP_SERVER', 'Server error processing the SOAP message; retry later.', ['network']],
      ['0x8024400F', 'WU_E_PT_WMI_ERROR', 'An unspecified WMI error occurred.', ['repair']],
      ['0x80244010', 'WU_E_PT_EXCEEDED_MAX_SERVER_TRIPS', 'Too many round trips to the server.', ['reset', 'network']],
      ['0x80244011', 'WU_E_PT_SUS_SERVER_NOT_SET', 'The WUServer policy value is missing.', ['policy']],
      ['0x80244012', 'WU_E_PT_DOUBLE_INITIALIZATION', 'Object was initialised twice.', ['services']],
      ['0x80244013', 'WU_E_PT_INVALID_COMPUTER_NAME', 'The computer name could not be determined.', ['info']],
      ['0x80244015', 'WU_E_PT_REFRESH_CACHE_REQUIRED', 'Server changed or cookie invalid; local cache must be refreshed.', ['reset']],
      ['0x80244016', 'WU_E_PT_HTTP_STATUS_BAD_REQUEST', 'HTTP 400: the server could not process the request.', ['network', 'reset']],
      ['0x80244017', 'WU_E_PT_HTTP_STATUS_DENIED', 'HTTP 401: authentication required.', ['network', 'policy']],
      ['0x80244018', 'WU_E_PT_HTTP_STATUS_FORBIDDEN', 'HTTP 403: the server refused the request (often a proxy or firewall).', ['network', 'policy']],
      ['0x80244019', 'WU_E_PT_HTTP_STATUS_NOT_FOUND', 'HTTP 404: requested URI not found (often a bad WSUS URL).', ['network', 'policy']],
      ['0x8024401A', 'WU_E_PT_HTTP_STATUS_BAD_METHOD', 'HTTP 405: method not allowed.', ['network']],
      ['0x8024401B', 'WU_E_PT_HTTP_STATUS_PROXY_AUTH_REQ', 'HTTP 407: proxy authentication required.', ['network']],
      ['0x8024401C', 'WU_E_PT_HTTP_STATUS_REQUEST_TIMEOUT', 'HTTP 408: server timed out waiting for the request.', ['network']],
      ['0x8024401D', 'WU_E_PT_HTTP_STATUS_CONFLICT', 'HTTP 409: conflict with the resource state.', ['network']],
      ['0x8024401E', 'WU_E_PT_HTTP_STATUS_GONE', 'HTTP 410: resource no longer available.', ['network', 'reset']],
      ['0x8024401F', 'WU_E_PT_HTTP_STATUS_SERVER_ERROR', 'HTTP 500: internal server error.', ['network']],
      ['0x80244020', 'WU_E_PT_HTTP_STATUS_NOT_SUPPORTED', 'HTTP 501: functionality not supported by the server.', ['network']],
      ['0x80244021', 'WU_E_PT_HTTP_STATUS_BAD_GATEWAY', 'HTTP 502: bad response from an upstream gateway or proxy.', ['network']],
      ['0x80244022', 'WU_E_PT_HTTP_STATUS_SERVICE_UNAVAIL', 'HTTP 503: service temporarily overloaded.', ['network']],
      ['0x80244023', 'WU_E_PT_HTTP_STATUS_GATEWAY_TIMEOUT', 'HTTP 504: gateway timed out.', ['network']],
      ['0x80244024', 'WU_E_PT_HTTP_STATUS_VERSION_NOT_SUP', 'HTTP 505: HTTP version not supported.', ['network']],
      ['0x80244025', 'WU_E_PT_FILE_LOCATIONS_CHANGED', 'File location changed; internal state must be refreshed.', ['reset']],
      ['0x80244026', 'WU_E_PT_REGISTRATION_NOT_SUPPORTED', 'Registration with a non-WSUS server is not supported.', ['policy']],
      ['0x80244027', 'WU_E_PT_NO_AUTH_PLUGINS_REQUESTED', 'Server returned an empty authentication list.', ['policy', 'reset']],
      ['0x80244028', 'WU_E_PT_NO_AUTH_COOKIES_CREATED', 'No valid authentication cookies could be created.', ['reset', 'network']],
      ['0x80244029', 'WU_E_PT_INVALID_CONFIG_PROP', 'A configuration property value was wrong.', ['policy']],
      ['0x8024402A', 'WU_E_PT_CONFIG_PROP_MISSING', 'A configuration property value was missing.', ['policy']],
      ['0x8024402B', 'WU_E_PT_HTTP_STATUS_NOT_MAPPED', 'HTTP failure not covered by a more specific HTTP code.', ['network']],
      ['0x8024402C', 'WU_E_PT_WINHTTP_NAME_NOT_RESOLVED', 'Proxy or update server name could not be resolved (DNS).', ['network']],
      ['0x8024402F', 'WU_E_PT_ECP_SUCCEEDED_WITH_ERRORS', 'External cab processing finished with errors.', ['reset']],
      ['0x80244030', 'WU_E_PT_ECP_INIT_FAILED', 'External cab processor failed to initialise.', ['reset']],
      ['0x80244031', 'WU_E_PT_ECP_INVALID_FILE_FORMAT', 'A metadata file has an invalid format.', ['reset']],
      ['0x80244032', 'WU_E_PT_ECP_INVALID_METADATA', 'External cab processor found invalid metadata.', ['reset']],
      ['0x80244033', 'WU_E_PT_ECP_FAILURE_TO_EXTRACT_DIGEST', 'File digest could not be extracted from an external cab.', ['reset']],
      ['0x80244034', 'WU_E_PT_ECP_FAILURE_TO_DECOMPRESS_CAB_FILE', 'An external cab file could not be decompressed.', ['reset']],
      ['0x80244035', 'WU_E_PT_ECP_FILE_LOCATION_ERROR', 'External cab processor could not get file locations.', ['reset']],
      ['0x80244FFF', 'WU_E_PT_UNEXPECTED', 'Communication error not covered by a more specific code.', ['network', 'reset']],
      ['0x8024502D', 'WU_E_PT_SAME_REDIR_ID', 'Recovery could not download a newer redirector cab.', ['reset', 'network']],
      ['0x8024502E', 'WU_E_PT_NO_MANAGED_RECOVER', 'Redirector recovery skipped because the server is managed.', ['policy']]
    ]},
    { id: 'dm', name: 'Download Manager', rows: [
      ['0x80246001', 'WU_E_DM_URLNOTAVAILABLE', 'Requested file has no download URL.', ['reset']],
      ['0x80246002', 'WU_E_DM_INCORRECTFILEHASH', 'Downloaded file hash did not match.', ['reset']],
      ['0x80246003', 'WU_E_DM_UNKNOWNALGORITHM', 'File metadata asked for an unknown hash algorithm.', ['reset']],
      ['0x80246004', 'WU_E_DM_NEEDDOWNLOADREQUEST', 'A download request is required from the handler.', ['reset']],
      ['0x80246005', 'WU_E_DM_NONETWORK', 'No network connection for the download.', ['network']],
      ['0x80246006', 'WU_E_DM_WRONGBITSVERSION', 'Incompatible BITS version.', ['bits', 'repair']],
      ['0x80246007', 'WU_E_DM_NOTDOWNLOADED', 'The update has not been downloaded.', ['bits', 'reset']],
      ['0x80246008', 'WU_E_DM_FAILTOCONNECTTOBITS', 'Download manager could not connect to BITS.', ['bits', 'services']],
      ['0x80246009', 'WU_E_DM_BITSTRANSFERERROR', 'Unspecified BITS transfer error.', ['bits']],
      ['0x8024600A', 'WU_E_DM_DOWNLOADLOCATIONCHANGED', 'Download source moved; download must restart.', ['reset']],
      ['0x8024600B', 'WU_E_DM_CONTENTCHANGED', 'Update content changed in a new revision; download must restart.', ['reset']],
      ['0x80246FFF', 'WU_E_DM_UNEXPECTED', 'Download manager error not covered by a more specific code.', ['bits', 'reset']]
    ]},
    { id: 'uh', name: 'Update Handler', rows: [
      ['0x80242000', 'WU_E_UH_REMOTEUNAVAILABLE', 'No remote process available for the update handler.', ['services', 'reset']],
      ['0x80242001', 'WU_E_UH_LOCALONLY', 'Handler is local only; remote request refused.', ['reset']],
      ['0x80242002', 'WU_E_UH_UNKNOWNHANDLER', 'Update handler was not recognised.', ['reset']],
      ['0x80242003', 'WU_E_UH_REMOTEALREADYACTIVE', 'A remote update handler already exists.', ['services']],
      ['0x80242004', 'WU_E_UH_DOESNOTSUPPORTACTION', 'The update does not support install or uninstall.', ['info']],
      ['0x80242005', 'WU_E_UH_WRONGHANDLER', 'The wrong handler was specified.', ['reset']],
      ['0x80242006', 'WU_E_UH_INVALIDMETADATA', 'The update contains invalid metadata.', ['reset']],
      ['0x80242007', 'WU_E_UH_INSTALLERHUNG', 'The installer exceeded its time limit.', ['reboot', 'reset']],
      ['0x80242008', 'WU_E_UH_OPERATIONCANCELLED', 'The handler operation was cancelled.', ['info']],
      ['0x80242009', 'WU_E_UH_BADHANDLERXML', 'Handler-specific metadata is invalid.', ['reset']],
      ['0x8024200A', 'WU_E_UH_CANREQUIREINPUT', 'The update needs user input to install.', ['info']],
      ['0x8024200B', 'WU_E_UH_INSTALLERFAILURE', 'The installer failed to install or uninstall one or more updates.', ['repair', 'reset']],
      ['0x8024200C', 'WU_E_UH_FALLBACKTOSELFCONTAINED', 'Handler should use full content instead of delta content.', ['reset']],
      ['0x8024200D', 'WU_E_UH_NEEDANOTHERDOWNLOAD', 'The update must be downloaded again.', ['reset']],
      ['0x8024200E', 'WU_E_UH_NOTIFYFAILURE', 'Handler could not report install status.', ['services']],
      ['0x8024200F', 'WU_E_UH_INCONSISTENT_FILE_NAMES', 'File names in the metadata and the package do not match.', ['reset']],
      ['0x80242010', 'WU_E_UH_FALLBACKERROR', 'Handler could not fall back to full content.', ['reset']],
      ['0x80242011', 'WU_E_UH_TOOMANYDOWNLOADREQUESTS', 'Handler exceeded the maximum download requests.', ['reset']],
      ['0x80242012', 'WU_E_UH_UNEXPECTEDCBSRESPONSE', 'Unexpected response from Component Based Servicing.', ['repair']],
      ['0x80242013', 'WU_E_UH_BADCBSPACKAGEID', 'Invalid CBS package identifier in the metadata.', ['repair', 'reset']],
      ['0x80242014', 'WU_E_UH_POSTREBOOTSTILLPENDING', 'Post-restart operation is still in progress.', ['reboot']],
      ['0x80242015', 'WU_E_UH_POSTREBOOTRESULTUNKNOWN', 'Post-restart result could not be determined.', ['reboot']],
      ['0x80242016', 'WU_E_UH_POSTREBOOTUNEXPECTEDSTATE', 'Unexpected update state after the post-restart operation.', ['reboot', 'repair']],
      ['0x80242017', 'WU_E_UH_NEW_SERVICING_STACK_REQUIRED', 'The servicing stack must be updated first.', ['repair']],
      ['0x80242FFF', 'WU_E_UH_UNEXPECTED', 'Update handler error not covered by a more specific code.', ['reset', 'repair']]
    ]},
    { id: 'ds', name: 'Data Store', rows: [
      ['0x80248000', 'WU_E_DS_SHUTDOWN', 'Windows Update Agent was shutting down.', ['services']],
      ['0x80248001', 'WU_E_DS_INUSE', 'The data store was in use.', ['services']],
      ['0x80248002', 'WU_E_DS_INVALID', 'Data store state does not match the expected state.', ['reset']],
      ['0x80248003', 'WU_E_DS_TABLEMISSING', 'The data store is missing a table.', ['reset']],
      ['0x80248004', 'WU_E_DS_TABLEINCORRECT', 'A data store table has unexpected columns.', ['reset']],
      ['0x80248005', 'WU_E_DS_INVALIDTABLENAME', 'Table is not in the data store.', ['reset']],
      ['0x80248006', 'WU_E_DS_BADVERSION', 'Data store version does not match.', ['reset']],
      ['0x80248007', 'WU_E_DS_NODATA', 'Requested information is not in the data store.', ['reset']],
      ['0x80248008', 'WU_E_DS_MISSINGDATA', 'Data store is missing required information or has an unexpected NULL.', ['reset']],
      ['0x80248009', 'WU_E_DS_MISSINGREF', 'Data store has a reference to missing data.', ['reset']],
      ['0x8024800A', 'WU_E_DS_UNKNOWNHANDLER', 'Update handler not recognised; update not processed.', ['reset']],
      ['0x8024800B', 'WU_E_DS_CANTDELETE', 'Update still referenced by a service; not deleted.', ['info']],
      ['0x8024800C', 'WU_E_DS_LOCKTIMEOUTEXPIRED', 'Data store section could not be locked in time.', ['services', 'reset']],
      ['0x8024800D', 'WU_E_DS_NOCATEGORIES', 'Category has no parent and is not top-level.', ['reset']],
      ['0x8024800E', 'WU_E_DS_ROWEXISTS', 'A row with the same primary key exists.', ['reset']],
      ['0x8024800F', 'WU_E_DS_STOREFILELOCKED', 'Data store locked by another process.', ['services', 'reset']],
      ['0x80248010', 'WU_E_DS_CANNOTREGISTER', 'Data store cannot register with COM in this process.', ['services', 'repair']],
      ['0x80248011', 'WU_E_DS_UNABLETOSTART', 'Could not create a data store object in another process.', ['services', 'reset']],
      ['0x80248013', 'WU_E_DS_DUPLICATEUPDATEID', 'Server sent the same update with two revision IDs.', ['reset']],
      ['0x80248014', 'WU_E_DS_UNKNOWNSERVICE', 'The service is not in the data store.', ['reset']],
      ['0x80248015', 'WU_E_DS_SERVICEEXPIRED', 'The service registration has expired.', ['reset']],
      ['0x80248016', 'WU_E_DS_DECLINENOTALLOWED', 'A mandatory or deadline update cannot be hidden.', ['info']],
      ['0x80248017', 'WU_E_DS_TABLESESSIONMISMATCH', 'Table not closed; not associated with the session.', ['reset']],
      ['0x80248018', 'WU_E_DS_SESSIONLOCKMISMATCH', 'Table not closed; not associated with the session lock.', ['reset']],
      ['0x80248019', 'WU_E_DS_NEEDWINDOWSSERVICE', 'The built-in Windows Update service cannot be removed.', ['info']],
      ['0x8024801A', 'WU_E_DS_INVALIDOPERATION', 'The requested operation is not allowed.', ['info']],
      ['0x8024801B', 'WU_E_DS_SCHEMAMISMATCH', 'Data store schema does not match a backup table schema.', ['reset']],
      ['0x8024801C', 'WU_E_DS_RESETREQUIRED', 'The data store needs a session reset.', ['services', 'reset']],
      ['0x8024801D', 'WU_E_DS_IMPERSONATED', 'Operation requested with an impersonated identity.', ['info']],
      ['0x80248FFF', 'WU_E_DS_UNEXPECTED', 'Data store error not covered by a more specific code.', ['reset']]
    ]},
    { id: 'drv', name: 'Driver Util', rows: [
      ['0x8024C001', 'WU_E_DRV_PRUNED', 'A driver was skipped (not fatal).', ['info']],
      ['0x8024C002', 'WU_E_DRV_NOPROP_OR_LEGACY', 'A driver property could not be found.', ['info']],
      ['0x8024C003', 'WU_E_DRV_REG_MISMATCH', 'Driver registry value has an unexpected type.', ['info']],
      ['0x8024C004', 'WU_E_DRV_NO_METADATA', 'Driver update is missing metadata.', ['reset']],
      ['0x8024C005', 'WU_E_DRV_MISSING_ATTRIBUTE', 'Driver update is missing a required attribute.', ['reset']],
      ['0x8024C006', 'WU_E_DRV_SYNC_FAILED', 'Driver synchronisation failed.', ['reset', 'network']],
      ['0x8024C007', 'WU_E_DRV_NO_PRINTER_CONTENT', 'Printer synchronisation information is missing.', ['info']],
      ['0x8024CFFF', 'WU_E_DRV_UNEXPECTED', 'Driver error not covered by a more specific code.', ['reset']]
    ]},
    { id: 'wu', name: 'Windows Update (general)', rows: [
      ['0x80070020', 'InstallFileLocked', 'A file is in use, often by antivirus or backup software scanning it.', ['reboot', 'reset']],
      ['0x80070422', '', 'The Windows Update service is stopped or disabled.', ['services']],
      ['0x80240001', 'WU_E_NO_SERVICE', 'Windows Update Agent could not provide the service.', ['services', 'reset']],
      ['0x80240002', 'WU_E_MAX_CAPACITY_REACHED', 'Service capacity was exceeded.', ['reset']],
      ['0x80240003', 'WU_E_UNKNOWN_ID', 'An ID could not be found.', ['reset']],
      ['0x80240004', 'WU_E_NOT_INITIALIZED', 'An object could not be initialised.', ['services', 'reset']],
      ['0x80240005', 'WU_E_RANGEOVERLAP', 'Overlapping byte ranges were requested.', ['reset']],
      ['0x80240006', 'WU_E_TOOMANYRANGES', 'Too many byte ranges were requested.', ['reset']],
      ['0x80240007', 'WU_E_INVALIDINDEX', 'Invalid collection index.', ['reset']],
      ['0x80240008', 'WU_E_ITEMNOTFOUND', 'The queried item key was not found.', ['reset']],
      ['0x80240009', 'WU_E_OPERATIONINPROGRESS', 'A conflicting operation was already in progress.', ['info']],
      ['0x8024000A', 'WU_E_COULDNOTCANCEL', 'The operation could not be cancelled.', ['info']],
      ['0x8024000B', 'WU_E_CALL_CANCELLED', 'The operation was cancelled.', ['info']],
      ['0x8024000C', 'WU_E_NOOP', 'No operation was needed.', ['info']],
      ['0x8024000D', 'WU_E_XML_MISSINGDATA', 'Required data missing from the update XML.', ['reset']],
      ['0x8024000E', 'WU_E_XML_INVALID', 'Invalid data in the update XML.', ['reset']],
      ['0x8024000F', 'WU_E_CYCLE_DETECTED', 'Circular update relationships in the metadata.', ['reset']],
      ['0x80240010', 'WU_E_TOO_DEEP_RELATION', 'Update relationships too deep to evaluate.', ['reset']],
      ['0x80240011', 'WU_E_INVALID_RELATIONSHIP', 'Invalid update relationship detected.', ['reset']],
      ['0x80240012', 'WU_E_REG_VALUE_INVALID', 'An invalid registry value was read.', ['policy', 'reset']],
      ['0x80240013', 'WU_E_DUPLICATE_ITEM', 'Tried to add a duplicate item to a list.', ['reset']],
      ['0x80240016', 'WU_E_INSTALL_NOT_ALLOWED', 'Another install is running or a mandatory restart is pending.', ['reboot']],
      ['0x80240017', 'WU_E_NOT_APPLICABLE', 'No applicable updates.', ['info']],
      ['0x80240018', 'WU_E_NO_USERTOKEN', 'A required user token is missing.', ['info']],
      ['0x80240019', 'WU_E_EXCLUSIVE_INSTALL_CONFLICT', 'An exclusive update cannot install alongside others.', ['info']],
      ['0x8024001A', 'WU_E_POLICY_NOT_SET', 'A policy value was not set.', ['policy']],
      ['0x8024001B', 'WU_E_SELFUPDATE_IN_PROGRESS', 'Windows Update Agent is updating itself.', ['info']],
      ['0x8024001D', 'WU_E_INVALID_UPDATE', 'An update contains invalid metadata.', ['reset']],
      ['0x8024001E', 'WU_E_SERVICE_STOP', 'The service or system was shutting down.', ['services']],
      ['0x8024001F', 'WU_E_NO_CONNECTION', 'No network connection.', ['network']],
      ['0x80240020', 'WU_E_NO_INTERACTIVE_USER', 'No interactive user is signed in.', ['info']],
      ['0x80240021', 'WU_E_TIME_OUT', 'The operation timed out.', ['network', 'services']],
      ['0x80240022', 'WU_E_ALL_UPDATES_FAILED', 'The operation failed for every update.', ['reset', 'repair']],
      ['0x80240023', 'WU_E_EULAS_DECLINED', 'All license terms were declined.', ['info']],
      ['0x80240024', 'WU_E_NO_UPDATE', 'There are no updates.', ['info']],
      ['0x80240025', 'WU_E_USER_ACCESS_DISABLED', 'Group Policy blocks access to Windows Update.', ['policy']],
      ['0x80240026', 'WU_E_INVALID_UPDATE_TYPE', 'Invalid update type.', ['reset']],
      ['0x80240027', 'WU_E_URL_TOO_LONG', 'A URL exceeded the maximum length.', ['policy']],
      ['0x80240028', 'WU_E_UNINSTALL_NOT_ALLOWED', 'Uninstall refused because the request did not come from WSUS.', ['info']],
      ['0x80240029', 'WU_E_INVALID_PRODUCT_LICENSE', 'An unlicensed application may have caused missed updates.', ['info']],
      ['0x8024002A', 'WU_E_MISSING_HANDLER', 'A component needed to detect updates is missing.', ['repair']],
      ['0x8024002B', 'WU_E_LEGACYSERVER', 'The operation needs a newer server version.', ['policy']],
      ['0x8024002C', 'WU_E_BIN_SOURCE_ABSENT', 'Delta update needs its source files, which are missing.', ['reset']],
      ['0x8024002D', 'WU_E_SOURCE_ABSENT', 'Full-file update needs its source, which is missing.', ['reset', 'repair']],
      ['0x8024002E', 'WU_E_WU_DISABLED', 'Access to an unmanaged server is not allowed.', ['policy']],
      ['0x8024002F', 'WU_E_CALL_CANCELLED_BY_POLICY', 'Cancelled by the DisableWindowsUpdateAccess policy.', ['policy']],
      ['0x80240030', 'WU_E_INVALID_PROXY_SERVER', 'The proxy list format is invalid.', ['network']],
      ['0x80240031', 'WU_E_INVALID_FILE', 'A file is in the wrong format.', ['reset']],
      ['0x80240032', 'WU_E_INVALID_CRITERIA', 'Invalid search criteria string.', ['info']],
      ['0x80240033', 'WU_E_EULA_UNAVAILABLE', 'License terms could not be downloaded.', ['network']],
      ['0x80240034', 'WU_E_DOWNLOAD_FAILED', 'The update failed to download.', ['bits', 'reset', 'network']],
      ['0x80240035', 'WU_E_UPDATE_NOT_PROCESSED', 'The update was not processed.', ['reset']],
      ['0x80240036', 'WU_E_INVALID_OPERATION', 'The object state did not allow the operation.', ['info']],
      ['0x80240037', 'WU_E_NOT_SUPPORTED', 'The operation is not supported.', ['info']],
      ['0x80240038', 'WU_E_WINHTTP_INVALID_FILE', 'Downloaded file had an unexpected content type (often a proxy page).', ['network', 'reset']],
      ['0x80240039', 'WU_E_TOO_MANY_RESYNC', 'Server asked the agent to resync too many times.', ['reset']],
      ['0x80240040', 'WU_E_NO_SERVER_CORE_SUPPORT', 'API method not available on Server Core.', ['info']],
      ['0x80240041', 'WU_E_SYSPREP_IN_PROGRESS', 'Service unavailable while sysprep runs.', ['info']],
      ['0x80240042', 'WU_E_UNKNOWN_SERVICE', 'Update service is no longer registered with Automatic Updates.', ['services', 'reset']],
      ['0x80240043', 'WU_E_NO_UI_SUPPORT', 'No support for the Windows Update UI.', ['info']],
      ['0x80240FFF', 'WU_E_UNEXPECTED', 'Failure not covered by another error code.', ['reset', 'repair']]
    ]},
    { id: 'success', name: 'Success codes', rows: [
      ['0x00240001', 'WU_S_SERVICE_STOP', 'Windows Update Agent stopped successfully.', ['info']],
      ['0x00240002', 'WU_S_SELFUPDATE', 'Windows Update Agent updated itself.', ['info']],
      ['0x00240003', 'WU_S_UPDATE_ERROR', 'Completed, but some updates had errors.', ['reset']],
      ['0x00240004', 'WU_S_MARKED_FOR_DISCONNECT', 'A callback was marked to disconnect later.', ['info']],
      ['0x00240005', 'WU_S_REBOOT_REQUIRED', 'A restart is needed to finish installing.', ['reboot']],
      ['0x00240006', 'WU_S_ALREADY_INSTALLED', 'The update is already installed.', ['info']],
      ['0x00240007', 'WU_S_ALREADY_UNINSTALLED', 'The update to remove is not installed.', ['info']],
      ['0x00240008', 'WU_S_ALREADY_DOWNLOADED', 'The update was already downloaded.', ['info']]
    ]},
    { id: 'msi', name: 'Windows Installer (minor)', rows: [
      ['0x80241001', 'WU_E_MSI_WRONG_VERSION', 'Windows Installer is older than 3.1; updates may be missed.', ['repair']],
      ['0x80241002', 'WU_E_MSI_NOT_CONFIGURED', 'Windows Installer is not configured; updates may be missed.', ['services']],
      ['0x80241003', 'WU_E_MSP_DISABLED', 'Policy disables Windows Installer patching.', ['info']],
      ['0x80241004', 'WU_E_MSI_WRONG_APP_CONTEXT', 'The application is installed per-user.', ['info']],
      ['0x80241FFF', 'WU_E_MSP_UNEXPECTED', 'A Windows Installer failure may have caused missed updates.', ['services', 'repair']]
    ]},
    { id: 'setup', name: 'Windows Update Agent setup', rows: [
      ['0x8024D001', 'WU_E_SETUP_INVALID_INFDATA', 'Agent update failed: an INF file is invalid.', ['repair']],
      ['0x8024D002', 'WU_E_SETUP_INVALID_IDENTDATA', 'Agent update failed: wuident.cab is invalid.', ['reset']],
      ['0x8024D003', 'WU_E_SETUP_ALREADY_INITIALIZED', 'Agent update failed: setup initialised twice.', ['reboot']],
      ['0x8024D004', 'WU_E_SETUP_NOT_INITIALIZED', 'Agent update failed: setup never initialised.', ['reset', 'repair']],
      ['0x8024D005', 'WU_E_SETUP_SOURCE_VERSION_MISMATCH', 'Agent update failed: INF and source file versions differ.', ['repair']],
      ['0x8024D006', 'WU_E_SETUP_TARGET_VERSION_GREATER', 'Agent update failed: a target file is newer than the source.', ['info']],
      ['0x8024D007', 'WU_E_SETUP_REGISTRATION_FAILED', 'Agent update failed: regsvr32 returned an error.', ['repair']],
      ['0x8024D009', 'WU_E_SETUP_SKIP_UPDATE', 'Agent update skipped by a wuident.cab directive.', ['info']],
      ['0x8024D00A', 'WU_E_SETUP_UNSUPPORTED_CONFIGURATION', 'Agent update failed: configuration not supported.', ['info']],
      ['0x8024D00B', 'WU_E_SETUP_BLOCKED_CONFIGURATION', 'Agent update failed: the system blocks the update.', ['policy']],
      ['0x8024D00C', 'WU_E_SETUP_REBOOT_TO_FIX', 'Agent update failed: a restart is required.', ['reboot']],
      ['0x8024D00D', 'WU_E_SETUP_ALREADYRUNNING', 'Agent setup is already running.', ['info']],
      ['0x8024D00E', 'WU_E_SETUP_REBOOTREQUIRED', 'Agent setup needs a restart to finish.', ['reboot']],
      ['0x8024D00F', 'WU_E_SETUP_HANDLER_EXEC_FAILURE', 'Agent update failed: setup handler error.', ['repair']],
      ['0x8024D010', 'WU_E_SETUP_INVALID_REGISTRY_DATA', 'Agent update failed: invalid registry data.', ['repair', 'policy']],
      ['0x8024D013', 'WU_E_SETUP_WRONG_SERVER_VERSION', 'Agent update failed: server has no data for this version.', ['policy']],
      ['0x8024DFFF', 'WU_E_SETUP_UNEXPECTED', 'Agent update failed for an unlisted reason.', ['repair']]
    ]}
  ];

  // Flatten to a lookup. A code listed in two components (0x80243FFF) keeps its first entry.
  const CODES = [];
  const BY_CODE = Object.create(null);
  for (const c of COMPONENTS) {
    for (const [code, name, desc, playbooks] of c.rows) {
      const key = code.toUpperCase().replace(/^0X/, '0x');
      if (BY_CODE[key]) continue;
      const entry = { code: key, name, desc, playbooks, component: c.name, componentId: c.id };
      BY_CODE[key] = entry;
      CODES.push(entry);
    }
  }

  const api = { SOURCE_URL, COMPONENTS, CODES, BY_CODE };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.WU_DATA = api;
})(typeof self !== 'undefined' ? self : this);
