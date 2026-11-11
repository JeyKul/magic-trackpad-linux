// System Settings module for mt2d: talks JSON to the daemon's control socket.

#include <KPluginFactory>
#include <KQuickConfigModule>

#include <QJsonDocument>
#include <QProcess>
#include <QJsonObject>
#include <QStandardPaths>
#include <QVariantMap>

#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

class Mt2dKcm : public KQuickConfigModule
{
    Q_OBJECT

public:
    Mt2dKcm(QObject *parent, const KPluginMetaData &data)
        : KQuickConfigModule(parent, data)
    {
        setButtons(Apply | Default);
    }

    // The page keeps the draft config; these just hand the standard buttons to it
    void load() override
    {
        // The widget wrapper resets its own state on load and only mirrors ours
        // when it changes, so make sure the page's update is a change
        setRepresentsDefaults(false);
        Q_EMIT loadRequested();
    }
    void save() override
    {
        Q_EMIT saveRequested();
    }
    void defaults() override
    {
        Q_EMIT defaultsRequested();
    }

    Q_INVOKABLE void startService() const
    {
        QProcess::startDetached(QStringLiteral("systemctl"), {QStringLiteral("--user"), QStringLiteral("start"), QStringLiteral("mt2d.service")});
    }

    Q_INVOKABLE QVariantMap call(const QVariantMap &command) const
    {
        const QString runtime = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
        const QByteArray server = (runtime + QStringLiteral("/mt2d.sock")).toLocal8Bit();
        const QByteArray client = (runtime + QStringLiteral("/mt2d-kcm-%1.sock").arg(getpid())).toLocal8Bit();

        int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (fd < 0) {
            return error(QStringLiteral("socket failed"));
        }
        sockaddr_un local{};
        local.sun_family = AF_UNIX;
        qstrncpy(local.sun_path, client.constData(), sizeof(local.sun_path));
        unlink(local.sun_path);
        sockaddr_un remote{};
        remote.sun_family = AF_UNIX;
        qstrncpy(remote.sun_path, server.constData(), sizeof(remote.sun_path));
        timeval timeout{1, 500000};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

        QVariantMap reply;
        const QByteArray request = QJsonDocument(QJsonObject::fromVariantMap(command)).toJson(QJsonDocument::Compact);
        if (bind(fd, reinterpret_cast<sockaddr *>(&local), sizeof(local)) < 0
            || sendto(fd, request.constData(), request.size(), 0, reinterpret_cast<sockaddr *>(&remote), sizeof(remote)) < 0) {
            reply = error(QStringLiteral("not running"));
        } else {
            QByteArray buffer(65536, Qt::Uninitialized);
            const ssize_t n = recv(fd, buffer.data(), buffer.size(), 0);
            reply = n > 0 ? QJsonDocument::fromJson(buffer.left(n)).object().toVariantMap()
                          : error(QStringLiteral("not running"));
        }
        close(fd);
        unlink(local.sun_path);
        return reply;
    }

Q_SIGNALS:
    void loadRequested();
    void saveRequested();
    void defaultsRequested();

private:
    static QVariantMap error(const QString &message)
    {
        return {{QStringLiteral("ok"), false}, {QStringLiteral("error"), message}};
    }
};

K_PLUGIN_CLASS_WITH_JSON(Mt2dKcm, "kcm_mt2d.json")

#include "kcm_mt2d.moc"
