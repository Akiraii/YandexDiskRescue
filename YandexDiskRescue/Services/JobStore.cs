using System.Text.Json;
using Microsoft.Data.Sqlite;
using YandexDiskRescue.Models;

namespace YandexDiskRescue.Services;

/// <summary>Crash-consistent single-account queue, migrated once from previous jobs.json.</summary>
public sealed class JobStore
{
    public static readonly string Root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"YandexDiskRescue");
    private readonly string _dbPath=Path.Combine(Root,"data","jobs.sqlite");
    private string LegacyJson => Path.Combine(Root,"data","jobs.json");
    public JobStore()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_dbPath)!);
        Locked(()=> {Initialize();return true;});
    }
    private static Mutex GetMutex()=>new(false,@"Local\YDR_Jobs_"+Environment.UserName.Replace(' ','_'));
    private T Locked<T>(Func<T> action)
    {
        using var mutex=GetMutex();
        bool held=false;
        try
        {
            try {held=mutex.WaitOne(TimeSpan.FromSeconds(20));}catch(AbandonedMutexException){held=true;}
            if(!held)throw new TimeoutException("Очередь заблокирована другой копией приложения");
            return action();
        }
        finally {if(held)mutex.ReleaseMutex();}
    }
    private SqliteConnection Open()
    {
        var connection=new SqliteConnection(new SqliteConnectionStringBuilder {
            DataSource=_dbPath,Mode=SqliteOpenMode.ReadWriteCreate,Cache=SqliteCacheMode.Shared,
            Pooling=false,DefaultTimeout=10
        }.ToString());
        connection.Open();
        using var timeout=connection.CreateCommand();
        timeout.CommandText="PRAGMA busy_timeout=10000";timeout.ExecuteNonQuery();
        return connection;
    }
    private static void Exec(SqliteConnection db,string sql,SqliteTransaction? tx=null)
    {
        using var cmd=db.CreateCommand();cmd.CommandText=sql;cmd.Transaction=tx;cmd.ExecuteNonQuery();
    }
    private void Initialize()
    {
        using var db=Open();
        Exec(db,"PRAGMA journal_mode=WAL");
        Exec(db,"PRAGMA synchronous=FULL");
        Exec(db,"CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, payload TEXT NOT NULL)");
        Exec(db,"CREATE TABLE IF NOT EXISTS info (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
        if(!File.Exists(LegacyJson))return;
        using var countCmd=db.CreateCommand();countCmd.CommandText="SELECT COUNT(*) FROM jobs";
        if(Convert.ToInt64(countCmd.ExecuteScalar())>0)return;
        // In case migration crashes, JSON remains untouched until SQLite transaction commits.
        var old=JsonSerializer.Deserialize<List<BackupJob>>(File.ReadAllText(LegacyJson))
            ?? throw new InvalidDataException("Старая очередь повреждена, автоматически перезаписывать её нельзя");
        using var tx=db.BeginTransaction();
        foreach(var item in old)Insert(db,tx,item);
        tx.Commit();
        File.Move(LegacyJson,LegacyJson+".migrated",overwrite:true);
    }
    private static void Insert(SqliteConnection db,SqliteTransaction tx,BackupJob item)
    {
        using var cmd=db.CreateCommand();cmd.Transaction=tx;
        cmd.CommandText="INSERT INTO jobs(id,payload) VALUES($id,$json)";
        cmd.Parameters.AddWithValue("$id",item.Id.ToString("N"));
        cmd.Parameters.AddWithValue("$json",JsonSerializer.Serialize(item));
        cmd.ExecuteNonQuery();
    }
    private List<BackupJob> Read()
    {
        using var db=Open();
        using var cmd=db.CreateCommand();cmd.CommandText="SELECT payload FROM jobs ORDER BY rowid";
        using var reader=cmd.ExecuteReader();
        var all=new List<BackupJob>();
        while(reader.Read())
            all.Add(JsonSerializer.Deserialize<BackupJob>(reader.GetString(0))
                ?? throw new InvalidDataException("Повреждена запись в SQLite: результат не будет потерян при автоматической очистке"));
        return all;
    }
    private void Write(List<BackupJob> jobs)
    {
        using var db=Open();
        using var tx=db.BeginTransaction();
        Exec(db,"DELETE FROM jobs",tx);
        foreach(var item in jobs)Insert(db,tx,item);
        tx.Commit();
    }
    public List<BackupJob> Load()=>Locked(Read);
    public void Change(Action<List<BackupJob>> action)=>Locked(() => {
        var list=Read();action(list);Write(list);return true;
    });
}
