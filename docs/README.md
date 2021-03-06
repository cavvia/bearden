# How Bearden Works

Bearden takes CSV files, creates relational data out of them and then exports a
flattened version of this data to Redshift for analysis. Be sure to check the
ERD for a high-level overview of the data model.

## Importing

Data makes its way into Bearden when an Importer creates an [`Import`
record][import_model] on the [new import page][new_import]. The Importer chooses
a CSV file from their hard drive, picks a `Source` and enters a brief
description of the import.

Once submitted, the Importer will land on the [import show page][show_import]
where they can see the status of the import. From here the CSV file can be
downloaded should that be necessary and after the import is finished, any rows
with errors can also be downloaded.

### Import States

The `Import` model has a `state` column which is managed by the
[`ImportMicroMachine` class][import_mm]. The `Import` progresses along this
graph:

![Import graph][import_graph]

[import_model]: /app/models/import.rb
[new_import]: /app/views/imports/new.html.haml
[show_import]: /app/views/imports/show.html.haml
[import_mm]: /app/models/import_micro_machine.rb
[import_graph]: /docs/ImportMicroMachine_graph.png

### Import Workers

Importing a CSV file into Bearden is accomplished by workers. This process
starts in the [ImportsController][imports_controller], when it [calls
`parse`][import_parse] on the `Import` record. That, in turn, enqueues a
`ParseCsvImportJob`. That job creates `RawInput` records for each row in the CSV
file and then when it's done doing that kicks off a recursive job to apply each
in turn using the `RawInputTransformJob`. The last of these recursive jobs will
call `finalize` on the `Import` which enqueues the `FinalizeImportJob`. That job
exports any errors and broadcasts the result.

[imports_controller]: /app/controllers/imports_controller.rb
[import_parse]: /app/controllers/imports_controller.rb#L11

## Exporting

Data leaves Bearden and lands in Redshift when Heroku Scheduler runs the [`rake
redshift:sync` task][sync_task] and a [`Sync` record][sync_model] is created. To
follow along with the progress of a `Sync`, you could occasionally refresh the
[sync list page][sync_list]. The process is done in batches driven by an ENV var
called `BATCH_EXPORT_SIZE`, currently set to 1,000. Each batch of records is
resolved and then written to its own file on S3. When all batches have finished,
we truncate the table on Redshift and copy over the data.

Note: Sync seemed like a good word here, but it implies a two-way flow of data
and that's not what we have. Bearden writes data to Redshift, but doesn't read
anything. Another word might have been better, but sync is how we all talked
about it. Language is weird.

[sync_task]: /lib/tasks/redshift.rake
[sync_model]: /app/models/sync.rb
[sync_list]: /app/views/syncs/index.html.haml

### Sync States

The `Sync` model has a `state` column which is managed by the
[`SyncMicroMachine` class][sync_mm]. The `Sync` progresses along this graph:

![Sync graph][sync_graph]

[sync_mm]: /app/models/sync_micro_machine.rb
[sync_graph]: /docs/SyncMicroMachine_graph.png

### Sync Workers

Exporting data to Redshift is accomplished by workers. Every 10 minutes when the
sync task is run it enqueues a [`SyncManagementJob`][sync_mgmt] which does one
of these things:

* creates a new `Sync`
* kicks off copying when a `Sync` is ready for it
* nothing

When there are no in-progress `Sync` records, then [a new one is
started][sync_start] and that enqueues a [`StartSyncJob`][sync_start_job]. This
job will either skip if there's nothing to do or split up the data into
manageable chucks and enqueue [`OrganizationExportJobs`][org_export_job] for
each part.

The jobs to export a batch of `Organization` records are processed
asynchronously and that happens on its own queue because it's very memory
intensive. This is where we resolve and flatten our relational data using the
aptly named [`OrganizationResolver`][org_resolver].

The second thing the management job could do is to [call `copy`][sync_copy] on
an existing `Sync` record. Copying a Sync is another way of saying that you're
going to finish it, thus this method enqueues a
[`FinishSyncJob`][sync_finish_job]. This job collaborates with the
[`DataWarehouse`][data_warehouse] to truncate and copy all data from S3 to
Redshift.

[sync_mgmt]: /app/jobs/sync_management_job.rb
[sync_start]: /app/models/sync.rb#L8
[sync_start_job]: /app/jobs/start_sync_job.rb
[org_export_job]: /app/jobs/organization_export_job.rb
[org_resolver]: /app/models/organization_resolver.rb
[sync_copy]: /app/models/sync.rb#L25
[sync_finish_job]: /app/jobs/finish_sync_job.rb
[data_warehouse]: /app/models/data_warehouse.rb

## Resolving Organizations with Sources and Ranking

Yes, Bearden imports and exports, but the thing that makes it special is the way
it models data and resolves `Organization` records.

Rather than simply having, for example, an email column on the organizations
table, we have a table of email addresses that point to their organization. This
means the actual `Organization` has very little data. It serves mostly as a way
to connect all the details of an entity.

Each of these details, such as an email, location, phone number and so on,
points back to the `Source` that created it. Consider the following graph.

![Organization and email graph][org_email_graph]

Given multiple fields, an organization resolves to the lowest ranked source for
that field. Since `email_2` originates from the lower-ranked `source_b`, the
output to Redshift will only contain `email_2`. The higher-ranked values are
ignored. (See also "the Rules" section.)

Source ranking resolution happens at export time — during the process of syncing
with Redshift. Waiting until this point in the process means that we delay the
flattening as long as possible and reflect information from the best-ranked
source.

[org_email_graph]: /docs/graphs/org-email.dot.png

### Rankables

A module called [`Rankable`][rankable] was extracted to wrap up the common
behavior among classes that are created by `RawInput` records. The important
thing it provides is a common way to get the rank of a particular record. It
uses the `versions` table to reach back to the actor that created the record and
then from there walk back up to the `Source` that has a rank.

[rankable]: /app/models/rankable.rb

### The Rules

The resolution rules are:

* use the `Rankable` with the lowest rank (1 is better than 2)
* break rank ties with `created_at` (newer is better)

### Ranking by Field

We started with a `rank` column on `sources`, but then realized that we wanted
more control. Some sources are good at emails, but bad at locations and
vice-versa. In order to accomplish this, we have a rank column for each
`Rankable`:

```
bearden_development=# \d sources
                                           Table "public.sources"
         Column         |            Type             |                      Modifiers
------------------------+-----------------------------+------------------------------------------------------
 id                     | integer                     | not null default nextval('sources_id_seq'::regclass)
 name                   | character varying           |
 created_at             | timestamp without time zone | not null
 updated_at             | timestamp without time zone | not null
 email_rank             | integer                     |
 location_rank          | integer                     |
 organization_name_rank | integer                     |
 phone_number_rank      | integer                     |
 website_rank           | integer                     |
 organization_type_rank | integer                     |
```

These ranks are set when creating a [new Source][new_source] or when [editing an
existing source][edit_source] and when this happens, the shifting ranks can
cause all of our Source records to be mutated. Managing this is done by the
[`SourceResolver`][source_resolver].

[new_source]: /app/views/sources/new.html.haml
[edit_source]: /app/views/sources/edit.html.haml
[source_resolver]: /app/models/source_resolver.rb
