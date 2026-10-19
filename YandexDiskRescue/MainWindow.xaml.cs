using System.Collections.ObjectModel;
using System.Windows;
using System.Diagnostics;
using Microsoft.Win32;
using YandexDiskRescue.Models;
using YandexDiskRescue.Services;

namespace YandexDiskRescue;
public partial class MainWindow : Window
{
    private RcloneSession? _session;
    private CancellationTokenSource? _taskCancellation;
    private readonly JobStore _store = new();
    private readonly ObservableCollection<BackupJob> _jobs = new();
    private bool _busy;
    private bool _initializing=true;
    private long _workerLogOffset;
    public MainWindow()
    {
        InitializeComponent();
        JobsList.ItemsSource = _jobs;
        AutostartCheck.IsChecked=StartupRegistration.Enabled;
        UnlimitedScriptBox.Text=Path.Combine(AppContext.BaseDirectory,"tools","yd.js");
        _initializing=false;
        try { RefreshJobs(); }
        catch (Exception ex) { Append("Ошибка загрузки очереди: " + ex.Message); }
        var timer=new System.Windows.Threading.DispatcherTimer{Interval=TimeSpan.FromSeconds(2)};
        timer.Tick+=(_,_)=>{RefreshJobs();ReadWorkerLog();}; timer.Start();
        Closing += (_, _) => { _taskCancellation?.Cancel(); _session?.Dispose(); };
    }
    private void Append(string text) => Dispatcher.BeginInvoke(() => { OutputBox.AppendText(text + Environment.NewLine); OutputBox.ScrollToEnd(); });
    private void Status(string text) => Dispatcher.BeginInvoke(() => JobStatus.Text = text);
    private void TokenChanged(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        _session?.Dispose(); _session = null;
        ConnectionStatus.Text = "Не подключено";
    }
    private async void ConnectClick(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        try
        {
            _session?.Dispose(); _session = new RcloneSession(TokenBox.Password.Trim());
            int exit = await ExecuteAsync("Проверка подключения", "about", new[] { "ydr:" });
            ConnectionStatus.Text = exit == 0 ? "Подключено" : "Не удалось подключиться";
            if (exit==0 && SaveTokenCheck.IsChecked==true) {
                SecureTokenStore.Save(TokenBox.Password.Trim());
                _store.Change(all=> {foreach(var j in all.Where(x=>x.State=="Нужна авторизация"))j.State="Ожидает";});
                StartWorker();
            }
            if (exit != 0) { _session.Dispose(); _session = null; }
        }
        catch (Exception ex) { ConnectionStatus.Text = "Не подключено"; Append("Ошибка: " + ex.Message); }
    }
    private string RemotePath()
    {
        string path = SourceBox.Text.Trim().Replace('\\', '/').TrimStart('/');
        if (path.StartsWith("ydr:", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Введите путь без префикса ydr:");
        if (path.Split('/').Any(x => x is "." or "..") || path.Contains('\n') || path.Contains('\r')) throw new ArgumentException("Недопустимый путь в облаке");
        return "ydr:" + path;
    }
    private async void ListClick(object sender, RoutedEventArgs e)
    {
        if (_session == null) { Append("Сначала подключите Диск."); return; }
        try { await ExecuteAsync("Список файлов", "lsf", new[] { RemotePath(), "--max-depth", "2" }); }
        catch (Exception ex) { Append("Ошибка: " + ex.Message); }
    }
    private void BrowseClick(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Выберите папку для резервной копии" };
        if (dialog.ShowDialog(this) == true) DestinationBox.Text = dialog.FolderName;
    }
    private void TransfersChanged(object sender, RoutedPropertyChangedEventArgs<double> e) { }
    private void ReadWorkerLog()
    {
        try
        {
            string log=Path.Combine(JobStore.Root,"log","worker.log");
            if(!File.Exists(log))return;
            using var fs=new FileStream(log,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
            if(fs.Length<_workerLogOffset)_workerLogOffset=0; // rotated
            // On opening GUI, show latest logs rather than reading multi-GB history.
            if(_workerLogOffset==0 && fs.Length>65536)_workerLogOffset=fs.Length-65536;
            fs.Seek(_workerLogOffset,SeekOrigin.Begin);
            using var reader=new StreamReader(fs,System.Text.Encoding.UTF8,detectEncodingFromByteOrderMarks:true,leaveOpen:true);
            string text=reader.ReadToEnd();
            _workerLogOffset=fs.Position;
            if(text.Length>0)
            {
                bool atBottom=OutputBox.VerticalOffset>=OutputBox.ExtentHeight-OutputBox.ViewportHeight-20;
                OutputBox.AppendText(text);
                if(atBottom)OutputBox.ScrollToEnd();
            }
        }
        catch(IOException) { /* worker rotating journal */ }
        catch(Exception ex) {Status("Журнал: "+ex.Message);}
    }
    private void RefreshJobs()
    {
        try
        {
            Guid? selected=(JobsList.SelectedItem as BackupJob)?.Id;
            _jobs.Clear(); foreach(var job in _store.Load()) _jobs.Add(job);
            JobsList.SelectedItem=_jobs.FirstOrDefault(x=>x.Id==selected);
        }
        catch(Exception ex) { Append("Не удалось обновить очередь: "+ex.Message); }
    }
    private void StartClick(object sender, RoutedEventArgs e)
    {
        try
        {
            string dest=Path.GetFullPath(DestinationBox.Text.Trim());
            if(!Path.IsPathFullyQualified(dest)) throw new ArgumentException("Требуется полный путь");
            string source=RemotePath();
            string serial=VolumeGuard.Capture(dest);
            _store.Change(jobs=> {
                if(jobs.Any(x=>x.Source==source && string.Equals(x.Destination,dest,StringComparison.OrdinalIgnoreCase) && x.State is "Ожидает" or "Копирование" or "Проверка")) throw new InvalidOperationException("Такое задание уже есть");
                if (!int.TryParse(BandwidthBox.Text.Trim(), out var limit) || limit < 0 || limit > 1048576) throw new ArgumentException("Лимит скорости: 0..1048576 КиБ/с");
                DateTime? scheduled = null;
                bool recurring=RecurringDailyCheck.IsChecked==true;
                var okTime=TimeSpan.TryParseExact(ScheduleTime.Text.Trim(), @"hh\:mm",
                    System.Globalization.CultureInfo.InvariantCulture, out var time);
                if((ScheduleDate.SelectedDate.HasValue || recurring) && !okTime)
                    throw new ArgumentException("Введите время в формате ЧЧ:мм");
                if(ScheduleDate.SelectedDate is DateTime date)
                    scheduled=DateTime.SpecifyKind(date.Date.Add(time),DateTimeKind.Local).ToUniversalTime();
                else if(recurring)
                {
                    var local=DateTime.Today.Add(time);
                    if(local<=DateTime.Now)local=local.AddDays(1);
                    scheduled=DateTime.SpecifyKind(local,DateTimeKind.Local).ToUniversalTime();
                }
                jobs.Add(new BackupJob{Source=source,Destination=dest,Transfers=(int)TransfersSlider.Value,
                    Verify=VerifyAfterCopy.IsChecked==true,LimitKiBPerSecond=limit,
                    NotBeforeUtc=scheduled,VolumeSerial=serial,RecurringDaily=recurring,
                    DailyMinuteOfDay=(int)time.TotalMinutes});
            });
            RefreshJobs(); StartWorker();
        }
        catch(Exception ex) {Append("Ошибка задания: "+ex.Message);}
    }
    private void PauseJobClick(object sender,RoutedEventArgs e)
    {
        if(JobsList.SelectedItem is not BackupJob selected)return;
        _store.Change(all=> {var j=all.FirstOrDefault(x=>x.Id==selected.Id);
            if(j!=null && j.State is ("Ожидает" or "Копирование" or "Проверка"))
            {j.State="Приостановлено";j.Details="Пауза по запросу пользователя";}});
        RefreshJobs();
    }
    private void CancelJobClick(object sender,RoutedEventArgs e)
    {
        if(JobsList.SelectedItem is not BackupJob selected)return;
        if(MessageBox.Show(this,"Отменить выбранное задание? Уже сохранённые локальные файлы не удаляются.",
            "Отмена задания",MessageBoxButton.YesNo,MessageBoxImage.Warning)!=MessageBoxResult.Yes)return;
        _store.Change(all=> {var j=all.FirstOrDefault(x=>x.Id==selected.Id);
            if(j!=null && j.State is not ("Завершено" or "Ошибка" or "Отменено"))
            {j.State="Отменено";j.Details="Отменено пользователем";}});
        RefreshJobs();
    }
    private void ResumeClick(object sender,RoutedEventArgs e)
    {
        if(JobsList.SelectedItem is not BackupJob job) return;
        _store.Change(all=> {var j=all.FirstOrDefault(x=>x.Id==job.Id);if(j!=null && j.State is not ("Копирование" or "Проверка")) {j.VolumeSerial=VolumeGuard.Capture(j.Destination);j.State="Ожидает";j.Details="";j.FinishedUtc=null;j.RetryCount=0;j.NextAttemptUtc=null;}});
        RefreshJobs();StartWorker();
    }
    private void StartWorker()
    {
        if(SaveTokenCheck.IsChecked!=true) {Append("Для фоновой работы разрешите сохранение токена (DPAPI) и подключитесь повторно.");return;}
        string file=System.IO.Path.Combine(AppContext.BaseDirectory,"Rescue.Worker.exe");
        if(!File.Exists(file)) {Append("Rescue.Worker.exe не найден рядом с GUI. Соберите и скопируйте оба EXE.");return;}
        try {System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(file){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=AppContext.BaseDirectory});Append("Worker запущен (или уже работает).");}
        catch(Exception ex) {Append("Не удалось запустить worker: "+ex.Message);}
    }
    private async Task<int> ExecuteAsync(string label,string verb,IEnumerable<string> args)
    {
        if (_session is null) throw new InvalidOperationException("Диск не подключён");
        if (_busy) throw new InvalidOperationException("Другая операция уже выполняется");
        _busy=true;
        using var cancel=new CancellationTokenSource();
        _taskCancellation=cancel;
        CancelButton.IsEnabled=true;
        Status(label);
        try
        {
            int code=await _session.RunAsync(verb,args,Append,cancel.Token);
            Append(label+": код завершения "+code);
            return code;
        }
        catch(OperationCanceledException) { Append(label+": отменено");return -1; }
        finally { _busy=false;_taskCancellation=null;CancelButton.IsEnabled=false;Status("Ожидание"); }
    }
    private void VerifySelectedClick(object sender,RoutedEventArgs e)
    {
        if(JobsList.SelectedItem is not BackupJob job) {Append("Выберите задание для проверки.");return;}
        try
        {
            _store.Change(all=>all.Add(new BackupJob{Source=job.Source,Destination=job.Destination,Transfers=job.Transfers,Kind="Проверка",Verify=true,UnlimitedManifestPath=job.UnlimitedManifestPath,VolumeSerial=VolumeGuard.Capture(job.Destination)}));
            RefreshJobs();StartWorker();
        }
        catch(Exception ex){Append("Ошибка проверки: "+ex.Message);}
    }
    private void OpenReportClick(object sender,RoutedEventArgs e)
    {
        if(JobsList.SelectedItem is not BackupJob job || string.IsNullOrWhiteSpace(job.ReportPath) || !File.Exists(job.ReportPath))
        {Append("Отчёт для этого задания ещё не создан.");return;}
        try {Process.Start(new ProcessStartInfo(job.ReportPath){UseShellExecute=true});}
        catch(Exception ex){Append("Не удалось открыть отчёт: "+ex.Message);}
    }
    private void CancelClick(object sender,RoutedEventArgs e) => _taskCancellation?.Cancel();
    private void DeleteTokenClick(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this,"Удалить сохранённый токен? Фоновое копирование перестанет работать до повторного подключения.","Подтверждение",MessageBoxButton.YesNo,MessageBoxImage.Warning)!=MessageBoxResult.Yes) return;
        try { SecureTokenStore.Delete(); SaveTokenCheck.IsChecked=false; Append("Сохранённый токен удалён."); }
        catch(Exception ex) { Append("Не удалось удалить токен: "+ex.Message); }
    }
    private async void UnlimitedQuotaClick(object sender, RoutedEventArgs e)
    {
        var token = TokenBox.Password.Trim();
        if (string.IsNullOrWhiteSpace(token)) { Append("Для проверки квоты введите OAuth-токен."); return; }
        try
        {
            UnlimitedQuotaStatus.Text = "Проверяю…";
            var summary = await UnlimitedPhotos.GetQuotaAsync(token, CancellationToken.None);
            UnlimitedQuotaStatus.Text = summary.ToString();
            Append("Квота безлимита: " + summary);
        }
        catch (Exception ex) { UnlimitedQuotaStatus.Text="Ошибка проверки"; Append("Проверка квоты: " + ex.Message); }
    }
    private void UnlimitedBrowseScriptClick(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title="Выберите yd.js из исходного репозитория", Filter="JavaScript yd.js|yd.js" };
        if (dialog.ShowDialog(this)==true) UnlimitedScriptBox.Text=dialog.FileName;
    }
    private void UnlimitedChromeClick(object sender, RoutedEventArgs e)
    {
        try { UnlimitedPhotos.StartIsolatedChrome(); Append("Открыт отдельный профиль Chrome. Войдите в Яндекс Диск в этом окне."); }
        catch (Exception ex) { Append("Chrome: " + ex.Message); }
    }
    private async void UnlimitedListClick(object sender, RoutedEventArgs e)
    {
        // Replacing the manifest after a partial move would lose evidence of earlier rescued files.
        try
        {
            if(UnlimitedPhotos.ReadMovedSet().Count>0)
            {
                Append("Список уже содержит переносы. Для продолжения используйте существующий список. Его нельзя перезаписывать до завершения архива.");
                return;
            }
        }
        catch(Exception ex) { Append("Проверка состояния безлимита: " + ex.Message);return; }
        await RunUnlimitedAsync("list", false);
    }
    private async void UnlimitedMoveClick(object sender, RoutedEventArgs e)
    {
        var msg = "Переместить фотографии ИЗ БЕЗЛИМИТА в обычную папку Яндекс Диска?\n\n"+
                  "Это изменит их расположение и они начнут занимать обычную квоту. "+
                  "Убедитесь, что папка «Безлимит» создана, свободного места достаточно, а список уже собран.\n\n"+
                  "Перемещение не удаляет файлы, но не является операцией только на чтение.";
        if(MessageBox.Show(this,msg,"Подтвердить изменение облачных данных",MessageBoxButton.YesNo,MessageBoxImage.Warning)!=MessageBoxResult.Yes) return;
        await RunUnlimitedAsync("move", true);
    }
    private async Task<bool> RunUnlimitedAsync(string action, bool changesCloud)
    {
        if (_busy) { Append("Дождитесь окончания текущей операции в окне."); return false; }
        _busy=true;
        using var cancel = new CancellationTokenSource();
        _taskCancellation=cancel;
        CancelButton.IsEnabled=true;
        Status(changesCloud?"Перенос безлимита":"Сбор списка безлимита");
        try
        {
            var script=UnlimitedScriptBox.Text.Trim();
            string accessToken=TokenBox.Password.Trim();
            if(string.IsNullOrWhiteSpace(accessToken))accessToken=SecureTokenStore.Read() ?? "";
            if(string.IsNullOrWhiteSpace(accessToken))throw new InvalidOperationException("Нужен OAuth-токен для сверки аккаунтов");
            var quota=await UnlimitedPhotos.GetQuotaAsync(accessToken,cancel.Token);
            if(action=="move")
            {
                if(!quota.EnoughForMove)throw new InvalidOperationException("Недостаточно обычной квоты с запасом для переноса фотографий");
                await UnlimitedPhotos.EnsureCloudFolderAsync(accessToken,cancel.Token);
            }
            int exit=await UnlimitedPhotos.RunScriptAsync(script,action,quota.AccountUid,Append,cancel.Token);
            Append((changesCloud?"Перенос":"Сбор списка")+": код завершения "+exit);
            if(exit==0 && changesCloud)
            {
                var (listed,expected,moved)=UnlimitedPhotos.ReadState();
                Append($"Состояние: список {listed}/{expected}; успешно перенесено {moved}. Теперь можно скачать перенесённые файлы и проверить.");
            }
            return exit==0;
        }
        catch(OperationCanceledException) { Append("Операция остановлена. Состояние сохранено в каталоге списка."); return false; }
        catch(Exception ex) { Append("Безлимит: " + ex.Message); return false; }
        finally { _taskCancellation=null; _busy=false;CancelButton.IsEnabled=false;Status("Ожидание"); }
    }
    private void UnlimitedStateClick(object sender,RoutedEventArgs e)
    {
        try {var (listed,expected,moved)=UnlimitedPhotos.ReadState();
            Append($"Безлимит: найдено {listed}, по счётчикам Яндекса {expected}, отмечено успешно перенесёнными {moved}.");
            if(listed!=expected) Append("ВНИМАНИЕ: список отличается от счётчиков Яндекса; возможно, фотографии пропущены.");
        }catch(Exception ex){Append("Проверка списка: "+ex.Message);}
    }
    private void UnlimitedDownloadClick(object sender,RoutedEventArgs e)
    {
        try
        {
            var (listed,expected,moved)=UnlimitedPhotos.ReadState();
            if(moved==0) throw new InvalidOperationException("Нет подтверждённых переносов в журнале yd.js.");
            if(moved<listed) Append($"Внимание: перенесено {moved} из {listed}; остальные пока не будут доступны через rclone.");
            string destination=Path.GetFullPath(DestinationBox.Text.Trim());
            if(!Path.IsPathFullyQualified(destination)) throw new ArgumentException("Укажите полный локальный путь.");
            if(MessageBox.Show(this,$"Скачать папку «Безлимит» в {destination} и проверить MD5?\nПодтверждённых переносов: {moved}/{listed}.\nДанные облака не удаляются.","Сохранение фотографий",MessageBoxButton.YesNo,MessageBoxImage.Question)!=MessageBoxResult.Yes)return;
            string snapshot=UnlimitedAudit.CaptureSnapshot();
            string volume=VolumeGuard.Capture(destination);
            _store.Change(all=>all.Add(new BackupJob{Source="ydr:Безлимит",Destination=destination,Transfers=Math.Clamp((int)TransfersSlider.Value,1,32),Verify=true,Kind="Копирование безлимита",UnlimitedManifestPath=snapshot,VolumeSerial=volume}));
            RefreshJobs();StartWorker();Append("Скачивание безлимита поставлено в очередь с обязательной проверкой.");
        }catch(Exception ex){Append("Скачивание безлимита: "+ex.Message);}
    }
    private void UnlimitedClearProfileClick(object sender,RoutedEventArgs e)
    {
        // The active Chrome profile cannot be deleted until its dedicated window is closed.
        if(MessageBox.Show(this,"Закройте отдельное окно Chrome. Удалить его профиль вместе с cookies и сессией?","Удаление сессии",MessageBoxButton.YesNo,MessageBoxImage.Warning)!=MessageBoxResult.Yes)return;
        try{UnlimitedPhotos.ClearIsolatedProfile();Append("Профиль браузера удалён.");}
        catch(Exception ex){Append("Не удалось удалить профиль (закройте Chrome): "+ex.Message);}
    }
    private void AutostartChanged(object sender, RoutedEventArgs e)
    {
        if(_initializing)return;
        try
        {
            StartupRegistration.Set(AutostartCheck.IsChecked==true);
            Append(AutostartCheck.IsChecked==true ? "Worker будет запускаться при входе в Windows." : "Автозапуск Worker отключён.");
        }
        catch(Exception ex)
        {
            Append("Не удалось изменить автозапуск: "+ex.Message);
            AutostartCheck.IsChecked=StartupRegistration.Enabled;
        }
    }
    // One click starts a controlled, explicit workflow after the user signs in to isolated Chrome.
    private async void UnlimitedRescueClick(object sender, RoutedEventArgs e)
    {
        if(_busy){Append("Операция уже выполняется");return;}
        try
        {
            var token=TokenBox.Password.Trim();
            if(string.IsNullOrWhiteSpace(token))token=SecureTokenStore.Read() ?? "";
            if(string.IsNullOrWhiteSpace(token))throw new InvalidOperationException("Необходимо подключить Яндекс Диск");
            if(SaveTokenCheck.IsChecked!=true || string.IsNullOrWhiteSpace(SecureTokenStore.Read()))
                throw new InvalidOperationException("Включите сохранение токена DPAPI и выполните подключение: фоновое скачивание требует токен");
            var quota=await UnlimitedPhotos.GetQuotaAsync(token,CancellationToken.None);
            UnlimitedQuotaStatus.Text=quota.ToString();
            if(!quota.EnoughForMove)throw new InvalidOperationException("Недостаточно квоты с запасом 5% для переноса всего безлимита");
            string destination=Path.GetFullPath(DestinationBox.Text.Trim());
            string serial=VolumeGuard.Capture(destination);
            if(string.IsNullOrWhiteSpace(UnlimitedScriptBox.Text) || !File.Exists(UnlimitedScriptBox.Text))
                throw new FileNotFoundException("Не найден встроенный yd.js. Проверьте комплектность установки");
            var reply=MessageBox.Show(this,
                "Мастер соберёт список фотографий, ПЕРЕМЕСТИТ их из безлимита в папку «Безлимит» на Яндекс Диске " +
                "(изменится занимаемая квота), а затем скачает файлы на ПК с проверкой содержимого. " +
                "При необходимости программа создаст папку «Безлимит». Скачанное не удаляется. Chrome должен быть открыт и авторизован. " +
                "Разрешаете эти изменения облачных данных?",
                "Подтверждение полного спасения",MessageBoxButton.YesNo,MessageBoxImage.Warning);
            if(reply!=MessageBoxResult.Yes)return;
            bool existing=false;
            try{var (listed,expected,moved)=UnlimitedPhotos.ReadState();existing=moved>0 && listed>0;}
            catch(FileNotFoundException){} // a new rescue
            if(existing) Append("Обнаружен старый журнал переносов. Продолжаем по исходному списку без его перезаписи.");
            else if(!await RunUnlimitedAsync("list",false))throw new InvalidOperationException("Не удалось полностью получить список фото");
            var (count,expectedCount,alreadyMoved)=UnlimitedPhotos.ReadState();
            if(count!=expectedCount)throw new InvalidOperationException($"Неполный список фото ({count}/{expectedCount}). Перенос заблокирован");
            bool movedOk=true;
            for(int attempt=0;attempt<3;attempt++)
            {
                var progress=UnlimitedPhotos.ReadState();
                if(progress.Moved>=progress.Listed)break;
                if(attempt>0){Append($"Повтор переноса {attempt+1}/3 через 15 секунд");await Task.Delay(15000);}
                movedOk=await RunUnlimitedAsync("move",true);
                var after=UnlimitedPhotos.ReadState();
                if(after.Moved<=progress.Moved && !movedOk)break; // do not hammer Yandex
            }
            var (finalCount,_,movedCount)=UnlimitedPhotos.ReadState();
            Append($"В облаке перенесено {movedCount}/{finalCount}. Результат операции: {(movedOk?"без фатальной ошибки":"с ошибками")}.");
            // Even after an API failure, rescue successfully moved photos rather than losing the partial result.
            if(movedCount==0)throw new InvalidOperationException("Не удалось подтвердить ни один перенос");
            string manifest=UnlimitedAudit.CaptureSnapshot();
            _store.Change(all=>all.Add(new BackupJob{
                Source="ydr:Безлимит",Destination=destination,VolumeSerial=serial,UnlimitedManifestPath=manifest,
                Transfers=Math.Clamp((int)TransfersSlider.Value,1,32),Verify=true,Kind="Копирование безлимита"}));
            RefreshJobs();StartWorker();
            Append("Скачивание и полная проверка по содержимому запущены через фоновую очередь. Итог см. в CSV и HTML.");
        }
        catch(Exception ex){Append("Мастер спасения: "+ex.Message);}
    }
    private void ClearClick(object sender,RoutedEventArgs e)=>OutputBox.Clear();
}
